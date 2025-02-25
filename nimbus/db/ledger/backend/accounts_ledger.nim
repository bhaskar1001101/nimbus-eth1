# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[tables, hashes, sets],
  chronicles,
  eth/common,
  results,
  minilru,
  ../../../utils/mergeutils,
  ../../../evm/code_bytes,
  ../../../stateless/multi_keys,
  "../../.."/[constants, utils/utils],
  ../../access_list as ac_access_list,
  "../.."/[core_db, storage_types, transient_storage],
  ../../aristo/aristo_blobify

const
  debugAccountsLedgerRef = false
  codeLruSize = 16*1024
    # An LRU cache of 16K items gives roughly 90% hit rate anecdotally on a
    # small range of test blocks - this number could be studied in more detail
    # Per EIP-170, a the code of a contract can be up to `MAX_CODE_SIZE` = 24kb,
    # which would cause a worst case of 386MB memory usage though in reality
    # code sizes are much smaller - it would make sense to study these numbers
    # in greater detail.
  slotsLruSize = 16 * 1024

type
  AccountFlag = enum
    Alive
    IsNew
    Dirty
    Touched
    CodeChanged
    StorageChanged
    NewlyCreated # EIP-6780: self destruct only in same transaction

  AccountFlags = set[AccountFlag]

  AccountRef = ref object
    statement: CoreDbAccount
    accPath: Hash256
    flags: AccountFlags
    code: CodeBytesRef
    originalStorage: TableRef[UInt256, UInt256]
    overlayStorage: Table[UInt256, UInt256]

  WitnessData* = object
    storageKeys*: HashSet[UInt256]
    codeTouched*: bool

  AccountsLedgerRef* = ref object
    ledger: CoreDbAccRef # AccountLedger
    kvt: CoreDbKvtRef
    savePoint: LedgerSavePoint
    witnessCache: Table[EthAddress, WitnessData]
    isDirty: bool
    ripemdSpecial: bool
    storeSlotHash*: bool
    cache: Table[EthAddress, AccountRef]
      # Second-level cache for the ledger save point, which is cleared on every
      # persist
    code: LruCache[Hash256, CodeBytesRef]
      ## The code cache provides two main benefits:
      ##
      ## * duplicate code is shared in memory beween accounts
      ## * the jump destination table does not have to be recomputed for every
      ##   execution, for commonly called called contracts
      ##
      ## The former feature is specially important in the 2.3-2.7M block range
      ## when underpriced code opcodes are being run en masse - both advantages
      ## help performance broadly as well.

    slots: LruCache[UInt256, Hash256]
      ## Because the same slots often reappear, we want to avoid writing them
      ## over and over again to the database to avoid the WAL and compation
      ## write amplification that ensues

  ReadOnlyStateDB* = distinct AccountsLedgerRef

  TransactionState = enum
    Pending
    Committed
    RolledBack

  LedgerSavePoint* = ref object
    parentSavepoint: LedgerSavePoint
    cache: Table[EthAddress, AccountRef]
    dirty: Table[EthAddress, AccountRef]
    selfDestruct: HashSet[EthAddress]
    logEntries: seq[Log]
    accessList: ac_access_list.AccessList
    transientStorage: TransientStorage
    state: TransactionState
    when debugAccountsLedgerRef:
      depth: int

const
  emptyEthAccount = newAccount()

  resetFlags = {
    Dirty,
    IsNew,
    Touched,
    CodeChanged,
    StorageChanged,
    NewlyCreated
    }

when debugAccountsLedgerRef:
  import
    stew/byteutils

  proc inspectSavePoint(name: string, x: LedgerSavePoint) =
    debugEcho "*** ", name, ": ", x.depth, " ***"
    var sp = x
    while sp != nil:
      for address, acc in sp.cache:
        debugEcho address.toHex, " ", acc.flags
      sp = sp.parentSavepoint

template logTxt(info: static[string]): static[string] =
  "AccountsLedgerRef " & info

template toAccountKey(acc: AccountRef): Hash256 =
  acc.accPath

template toAccountKey(eAddr: EthAddress): Hash256 =
  eAddr.keccakHash


proc beginSavepoint*(ac: AccountsLedgerRef): LedgerSavePoint {.gcsafe.}

proc resetCoreDbAccount(ac: AccountsLedgerRef, acc: AccountRef) =
  const info = "resetCoreDbAccount(): "
  ac.ledger.clearStorage(acc.toAccountKey).isOkOr:
    raiseAssert info & $$error
  acc.statement.nonce = emptyEthAccount.nonce
  acc.statement.balance = emptyEthAccount.balance
  acc.statement.codeHash = emptyEthAccount.codeHash

# The AccountsLedgerRef is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[AccountsLedgerRef], db: CoreDbRef,
           root: KeccakHash, storeSlotHash: bool): AccountsLedgerRef =
  new result
  result.ledger = db.ctx.getAccounts()
  result.kvt = db.ctx.getKvt()
  result.witnessCache = Table[EthAddress, WitnessData]()
  result.storeSlotHash = storeSlotHash
  result.code = typeof(result.code).init(codeLruSize)
  result.slots = typeof(result.slots).init(slotsLruSize)
  discard result.beginSavepoint

proc init*(x: typedesc[AccountsLedgerRef], db: CoreDbRef): AccountsLedgerRef =
  init(x, db, EMPTY_ROOT_HASH)

# Renamed `rootHash()` => `state()`
proc state*(ac: AccountsLedgerRef): KeccakHash =
  const info = "state(): "
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # make sure all cache already committed
  doAssert(ac.isDirty == false)
  ac.ledger.state(updateOk=true).valueOr:
    raiseAssert info & $$error

proc isTopLevelClean*(ac: AccountsLedgerRef): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ac.isDirty and ac.savePoint.parentSavepoint.isNil

proc beginSavepoint*(ac: AccountsLedgerRef): LedgerSavePoint =
  new result
  result.cache = Table[EthAddress, AccountRef]()
  result.accessList.init()
  result.transientStorage.init()
  result.state = Pending
  result.parentSavepoint = ac.savePoint
  ac.savePoint = result

  when debugAccountsLedgerRef:
    if not result.parentSavePoint.isNil:
      result.depth = result.parentSavePoint.depth + 1
    inspectSavePoint("snapshot", result)

proc rollback*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  ac.savePoint = sp.parentSavepoint
  sp.state = RolledBack

  when debugAccountsLedgerRef:
    inspectSavePoint("rollback", ac.savePoint)

proc commit*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  # cannot commit most inner savepoint
  doAssert not sp.parentSavepoint.isNil

  ac.savePoint = sp.parentSavepoint
  ac.savePoint.cache.mergeAndReset(sp.cache)
  ac.savePoint.dirty.mergeAndReset(sp.dirty)
  ac.savePoint.transientStorage.mergeAndReset(sp.transientStorage)
  ac.savePoint.accessList.mergeAndReset(sp.accessList)
  ac.savePoint.selfDestruct.mergeAndReset(sp.selfDestruct)
  ac.savePoint.logEntries.mergeAndReset(sp.logEntries)
  sp.state = Committed

  when debugAccountsLedgerRef:
    inspectSavePoint("commit", ac.savePoint)

proc dispose*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
  if sp.state == Pending:
    ac.rollback(sp)

proc safeDispose*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
  if (not isNil(sp)) and (sp.state == Pending):
    ac.rollback(sp)

proc getAccount(
    ac: AccountsLedgerRef;
    address: EthAddress;
    shouldCreate = true;
      ): AccountRef =

  # search account from layers of cache
  var sp = ac.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      return
    sp = sp.parentSavepoint

  if ac.cache.pop(address, result):
    # Check second-level cache
    ac.savePoint.cache[address] = result
    return

  # not found in cache, look into state trie
  let
    accPath = address.toAccountKey
    rc = ac.ledger.fetch accPath
  if rc.isOk:
    result = AccountRef(
      statement: rc.value,
      accPath:   accPath,
      flags:     {Alive})
  elif shouldCreate:
    result = AccountRef(
      statement: CoreDbAccount(
        nonce:    emptyEthAccount.nonce,
        balance:  emptyEthAccount.balance,
        codeHash: emptyEthAccount.codeHash),
      accPath:    accPath,
      flags:      {Alive, IsNew})
  else:
    return # ignore, don't cache

  # cache the account
  ac.savePoint.cache[address] = result
  ac.savePoint.dirty[address] = result

proc clone(acc: AccountRef, cloneStorage: bool): AccountRef =
  result = AccountRef(
    statement: acc.statement,
    accPath:   acc.accPath,
    flags:     acc.flags,
    code:      acc.code)

  if cloneStorage:
    result.originalStorage = acc.originalStorage
    # it's ok to clone a table this way
    result.overlayStorage = acc.overlayStorage

proc isEmpty(acc: AccountRef): bool =
  acc.statement.nonce == 0 and
    acc.statement.balance.isZero and
    acc.statement.codeHash == EMPTY_CODE_HASH

template exists(acc: AccountRef): bool =
  Alive in acc.flags

proc originalStorageValue(
    acc: AccountRef;
    slot: UInt256;
    ac: AccountsLedgerRef;
      ): UInt256 =
  # share the same original storage between multiple
  # versions of account
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
  else:
    acc.originalStorage[].withValue(slot, val) do:
      return val[]

  # Not in the original values cache - go to the DB.
  let
    slotKey = ac.slots.get(slot).valueOr:
      slot.toBytesBE.keccakHash
    rc = ac.ledger.slotFetch(acc.toAccountKey, slotKey)
  if rc.isOk:
    result = rc.value

  acc.originalStorage[slot] = result

proc storageValue(
    acc: AccountRef;
    slot: UInt256;
    ac: AccountsLedgerRef;
      ): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(slot, ac)

proc kill(ac: AccountsLedgerRef, acc: AccountRef) =
  acc.flags.excl Alive
  acc.overlayStorage.clear()
  acc.originalStorage = nil
  ac.resetCoreDbAccount acc
  acc.code.reset()

type
  PersistMode = enum
    DoNothing
    Update
    Remove

proc persistMode(acc: AccountRef): PersistMode =
  result = DoNothing
  if Alive in acc.flags:
    if IsNew in acc.flags or Dirty in acc.flags:
      result = Update
  else:
    if IsNew notin acc.flags:
      result = Remove

proc persistCode(acc: AccountRef, ac: AccountsLedgerRef) =
  if acc.code.len != 0 and not acc.code.persisted:
    let rc = ac.kvt.put(
      contractHashKey(acc.statement.codeHash).toOpenArray, acc.code.bytes())
    if rc.isErr:
      warn logTxt "persistCode()",
       codeHash=acc.statement.codeHash, error=($$rc.error)
    else:
      # If the ledger changes rolled back entirely from the database, the ledger
      # code cache must also be cleared!
      acc.code.persisted = true

proc persistStorage(acc: AccountRef, ac: AccountsLedgerRef) =
  const info = "persistStorage(): "

  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return

  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  # Make sure that there is an account entry on the database. This is needed by
  # `Aristo` for updating the account's storage area reference. As a side effect,
  # this action also updates the latest statement data.
  ac.ledger.merge(acc.toAccountKey, acc.statement).isOkOr:
    raiseAssert info & $$error

  # Save `overlayStorage[]` on database
  for slot, value in acc.overlayStorage:
    acc.originalStorage[].withValue(slot, v):
      if v[] == value:
        continue # Avoid writing A-B-A updates

    var cached = true
    let slotKey = ac.slots.get(slot).valueOr:
      cached = false
      let hash = slot.toBytesBE.keccakHash
      ac.slots.put(slot, hash)
      hash

    if value > 0:
      ac.ledger.slotMerge(acc.toAccountKey, slotKey, value).isOkOr:
        raiseAssert info & $$error

      # move the overlayStorage to originalStorage, related to EIP2200, EIP1283
      acc.originalStorage[slot] = value

    else:
      ac.ledger.slotDelete(acc.toAccountKey, slotKey).isOkOr:
        if error.error != StoNotFound:
          raiseAssert info & $$error
        discard
      acc.originalStorage.del(slot)

    if ac.storeSlotHash and not cached:
      # Write only if it was not cached to avoid writing the same data over and
      # over..
      let
        key = slotKey.data.slotHashToSlotKey
        rc = ac.kvt.put(key.toOpenArray, blobify(slot).data)
      if rc.isErr:
        warn logTxt "persistStorage()", slot, error=($$rc.error)

  acc.overlayStorage.clear()

proc makeDirty(ac: AccountsLedgerRef, address: EthAddress, cloneStorage = true): AccountRef =
  ac.isDirty = true
  result = ac.getAccount(address)
  if address in ac.savePoint.cache:
    # it's already in latest savepoint
    result.flags.incl Dirty
    ac.savePoint.dirty[address] = result
    return

  # put a copy into latest savepoint
  result = result.clone(cloneStorage)
  result.flags.incl Dirty
  ac.savePoint.cache[address] = result
  ac.savePoint.dirty[address] = result

proc getCodeHash*(ac: AccountsLedgerRef, address: EthAddress): Hash256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyEthAccount.codeHash
  else: acc.statement.codeHash

proc getBalance*(ac: AccountsLedgerRef, address: EthAddress): UInt256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyEthAccount.balance
  else: acc.statement.balance

proc getNonce*(ac: AccountsLedgerRef, address: EthAddress): AccountNonce =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyEthAccount.nonce
  else: acc.statement.nonce

proc getCode*(ac: AccountsLedgerRef, address: EthAddress): CodeBytesRef =
  # Always returns non-nil!
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return CodeBytesRef()

  if acc.code == nil:
    acc.code =
      if acc.statement.codeHash != EMPTY_CODE_HASH:
        ac.code.get(acc.statement.codeHash).valueOr:
          var rc = ac.kvt.get(contractHashKey(acc.statement.codeHash).toOpenArray)
          if rc.isErr:
            warn logTxt "getCode()", codeHash=acc.statement.codeHash, error=($$rc.error)
            CodeBytesRef()
          else:
            let newCode = CodeBytesRef.init(move(rc.value), persisted = true)
            ac.code.put(acc.statement.codeHash, newCode)
            newCode
      else:
        CodeBytesRef()

  acc.code

proc getCodeSize*(ac: AccountsLedgerRef, address: EthAddress): int =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return 0

  if acc.code == nil:
    if acc.statement.codeHash == EMPTY_CODE_HASH:
      return 0
    acc.code = ac.code.get(acc.statement.codeHash).valueOr:
      # On a cache miss, we don't fetch the code - instead, we fetch just the
      # length - should the code itself be needed, it will typically remain
      # cached and easily accessible in the database layer - this is to prevent
      # EXTCODESIZE calls from messing up the code cache and thus causing
      # recomputation of the jump destination table
      var rc = ac.kvt.len(contractHashKey(acc.statement.codeHash).toOpenArray)

      return rc.valueOr:
        warn logTxt "getCodeSize()", codeHash=acc.statement.codeHash, error=($$rc.error)
        0

  acc.code.len()

proc getCommittedStorage*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): UInt256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.originalStorageValue(slot, ac)

proc getStorage*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): UInt256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.storageValue(slot, ac)

proc contractCollision*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.statement.nonce != 0 or
    acc.statement.codeHash != EMPTY_CODE_HASH or
      not ac.ledger.slotStateEmptyOrVoid(acc.toAccountKey)

proc accountExists*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.exists()

proc isEmptyAccount*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  doAssert not acc.isNil
  doAssert acc.exists()
  acc.isEmpty()

proc isDeadAccount*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return true
  if not acc.exists():
    return true
  acc.isEmpty()

proc setBalance*(ac: AccountsLedgerRef, address: EthAddress, balance: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  if acc.statement.balance != balance:
    ac.makeDirty(address).statement.balance = balance

proc addBalance*(ac: AccountsLedgerRef, address: EthAddress, delta: UInt256) =
  # EIP161: We must check emptiness for the objects such that the account
  # clearing (0,0,0 objects) can take effect.
  if delta.isZero:
    let acc = ac.getAccount(address)
    if acc.isEmpty:
      ac.makeDirty(address).flags.incl Touched
    return
  ac.setBalance(address, ac.getBalance(address) + delta)

proc subBalance*(ac: AccountsLedgerRef, address: EthAddress, delta: UInt256) =
  if delta.isZero:
    # This zero delta early exit is important as shown in EIP-4788.
    # If the account is created, it will change the state.
    # But early exit will prevent the account creation.
    # In this case, the SYSTEM_ADDRESS
    return
  ac.setBalance(address, ac.getBalance(address) - delta)

proc setNonce*(ac: AccountsLedgerRef, address: EthAddress, nonce: AccountNonce) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  if acc.statement.nonce != nonce:
    ac.makeDirty(address).statement.nonce = nonce

proc incNonce*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setCode*(ac: AccountsLedgerRef, address: EthAddress, code: seq[byte]) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let codeHash = keccakHash(code)
  if acc.statement.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.statement.codeHash = codeHash
    # Try to reuse cache entry if it exists, but don't save the code - it's not
    # a given that it will be executed within LRU range
    acc.code = ac.code.get(codeHash).valueOr(CodeBytesRef.init(code))
    acc.flags.incl CodeChanged

proc setStorage*(ac: AccountsLedgerRef, address: EthAddress, slot, value: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let oldValue = acc.storageValue(slot, ac)
  if oldValue != value:
    var acc = ac.makeDirty(address)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ac: AccountsLedgerRef, address: EthAddress) =
  const info = "clearStorage(): "

  # a.k.a createStateObject. If there is an existing account with
  # the given address, it is overwritten.

  let acc = ac.getAccount(address)
  acc.flags.incl {Alive, NewlyCreated}

  let empty = ac.ledger.slotStateEmpty(acc.toAccountKey).valueOr: return
  if not empty:
    # need to clear the storage from the database first
    let acc = ac.makeDirty(address, cloneStorage = false)
    ac.ledger.clearStorage(acc.toAccountKey).isOkOr:
      raiseAssert info & $$error
    # update caches
    if acc.originalStorage.isNil.not:
      # also clear originalStorage cache, otherwise
      # both getStorage and getCommittedStorage will
      # return wrong value
      acc.originalStorage.clear()

proc deleteAccount*(ac: AccountsLedgerRef, address: EthAddress) =
  # make sure all savepoints already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  let acc = ac.getAccount(address)
  ac.savePoint.dirty[address] = acc
  ac.kill acc

proc selfDestruct*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.setBalance(address, 0.u256)
  ac.savePoint.selfDestruct.incl address

proc selfDestruct6780*(ac: AccountsLedgerRef, address: EthAddress) =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return

  if NewlyCreated in acc.flags:
    ac.selfDestruct(address)

proc selfDestructLen*(ac: AccountsLedgerRef): int =
  ac.savePoint.selfDestruct.len

proc addLogEntry*(ac: AccountsLedgerRef, log: Log) =
  ac.savePoint.logEntries.add log

proc getAndClearLogEntries*(ac: AccountsLedgerRef): seq[Log] =
  swap(result, ac.savePoint.logEntries)

proc ripemdSpecial*(ac: AccountsLedgerRef) =
  ac.ripemdSpecial = true

proc deleteEmptyAccount(ac: AccountsLedgerRef, address: EthAddress) =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  if not acc.isEmpty:
    return
  if not acc.exists:
    return

  ac.savePoint.dirty[address] = acc
  ac.kill acc

proc clearEmptyAccounts(ac: AccountsLedgerRef) =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  for acc in ac.savePoint.dirty.values():
    if Touched in acc.flags and
        acc.isEmpty and acc.exists:
      ac.kill acc

  # https://github.com/ethereum/EIPs/issues/716
  if ac.ripemdSpecial:
    ac.deleteEmptyAccount(RIPEMD_ADDR)
    ac.ripemdSpecial = false

proc persist*(ac: AccountsLedgerRef,
              clearEmptyAccount: bool = false,
              clearCache = false) =
  const info = "persist(): "

  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)

  if clearEmptyAccount:
    ac.clearEmptyAccounts()

  for address in ac.savePoint.selfDestruct:
    ac.deleteAccount(address)

  for (eAddr,acc) in ac.savePoint.dirty.pairs(): # This is a hotspot in block processing
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(ac)
      if StorageChanged in acc.flags:
        acc.persistStorage(ac)
      else:
        # This one is only necessary unless `persistStorage()` is run which needs
        # to `merge()` the latest statement as well.
        ac.ledger.merge(acc.toAccountKey, acc.statement).isOkOr:
          raiseAssert info & $$error
    of Remove:
      ac.ledger.delete(acc.toAccountKey).isOkOr:
        if error.error != AccNotFound:
          raiseAssert info & $$error
      ac.savePoint.cache.del eAddr
    of DoNothing:
      # dead man tell no tales
      # remove touched dead account from cache
      if Alive notin acc.flags:
        ac.savePoint.cache.del eAddr

    acc.flags = acc.flags - resetFlags
  ac.savePoint.dirty.clear()

  if clearCache:
    # This overwrites the cache from the previous persist, providing a crude LRU
    # scheme with little overhead
    # TODO https://github.com/nim-lang/Nim/issues/23759
    swap(ac.cache, ac.savePoint.cache)
    ac.savePoint.cache.reset()

  ac.savePoint.selfDestruct.clear()

  # EIP2929
  ac.savePoint.accessList.clear()

  ac.isDirty = false

iterator addresses*(ac: AccountsLedgerRef): EthAddress =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for address, _ in ac.savePoint.cache:
    yield address

iterator accounts*(ac: AccountsLedgerRef): Account =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for _, acc in ac.savePoint.cache:
    yield ac.ledger.recast(
      acc.toAccountKey, acc.statement, updateOk=true).value

iterator pairs*(ac: AccountsLedgerRef): (EthAddress, Account) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for address, acc in ac.savePoint.cache:
    yield (address, ac.ledger.recast(
      acc.toAccountKey, acc.statement, updateOk=true).value)

iterator storage*(
    ac: AccountsLedgerRef;
    eAddr: EthAddress;
      ): (UInt256, UInt256) =
  # beware that if the account not persisted,
  # the storage root will not be updated
  for (slotHash, value) in ac.ledger.slotPairs eAddr.toAccountKey:
    let rc = ac.kvt.get(slotHashToSlotKey(slotHash).toOpenArray)
    if rc.isErr:
      warn logTxt "storage()", slotHash, error=($$rc.error)
      continue
    let r = deblobify(rc.value, UInt256)
    if r.isErr:
      warn logTxt "storage.deblobify", slotHash, msg=r.error
      continue
    yield (r.value, value)

iterator cachedStorage*(ac: AccountsLedgerRef, address: EthAddress): (UInt256, UInt256) =
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    if not acc.originalStorage.isNil:
      for k, v in acc.originalStorage:
        yield (k, v)

proc getStorageRoot*(ac: AccountsLedgerRef, address: EthAddress): Hash256 =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if acc.isNil: EMPTY_ROOT_HASH
  else: ac.ledger.slotState(acc.toAccountKey).valueOr: EMPTY_ROOT_HASH

proc update(wd: var WitnessData, acc: AccountRef) =
  # once the code is touched make sure it doesn't get reset back to false in another update
  if not wd.codeTouched:
    wd.codeTouched = CodeChanged in acc.flags or acc.code != nil

  if not acc.originalStorage.isNil:
    for k, v in acc.originalStorage:
      if v.isZero: continue
      wd.storageKeys.incl k

  for k, v in acc.overlayStorage:
    wd.storageKeys.incl k

proc witnessData(acc: AccountRef): WitnessData =
  result.storageKeys = HashSet[UInt256]()
  update(result, acc)

proc collectWitnessData*(ac: AccountsLedgerRef) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # usually witness data is collected before we call persist()
  for address, acc in ac.savePoint.cache:
    ac.witnessCache.withValue(address, val) do:
      update(val[], acc)
    do:
      ac.witnessCache[address] = witnessData(acc)

func multiKeys(slots: HashSet[UInt256]): MultiKeysRef =
  if slots.len == 0: return
  new result
  for x in slots:
    result.add x.toBytesBE
  result.sort()

proc makeMultiKeys*(ac: AccountsLedgerRef): MultiKeysRef =
  # this proc is called after we done executing a block
  new result
  for k, v in ac.witnessCache:
    result.add(k, v.codeTouched, multiKeys(v.storageKeys))
  result.sort()

proc accessList*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.savePoint.accessList.add(address)

proc accessList*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256) =
  ac.savePoint.accessList.add(address, slot)

func inAccessList*(ac: AccountsLedgerRef, address: EthAddress): bool =
  var sp = ac.savePoint
  while sp != nil:
    result = sp.accessList.contains(address)
    if result:
      return
    sp = sp.parentSavepoint

func inAccessList*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): bool =
  var sp = ac.savePoint
  while sp != nil:
    result = sp.accessList.contains(address, slot)
    if result:
      return
    sp = sp.parentSavepoint

func getTransientStorage*(ac: AccountsLedgerRef,
                          address: EthAddress, slot: UInt256): UInt256 =
  var sp = ac.savePoint
  while sp != nil:
    let (ok, res) = sp.transientStorage.getStorage(address, slot)
    if ok:
      return res
    sp = sp.parentSavepoint

proc setTransientStorage*(ac: AccountsLedgerRef,
                          address: EthAddress, slot, val: UInt256) =
  ac.savePoint.transientStorage.setStorage(address, slot, val)

proc clearTransientStorage*(ac: AccountsLedgerRef) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  ac.savePoint.transientStorage.clear()

func getAccessList*(ac: AccountsLedgerRef): common.AccessList =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  ac.savePoint.accessList.getAccessList()

proc getEthAccount*(ac: AccountsLedgerRef, address: EthAddress): Account =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return emptyEthAccount

  ## Convert to legacy object, will throw an assert if that fails
  let rc = ac.ledger.recast(acc.toAccountKey, acc.statement)
  if rc.isErr:
    raiseAssert "getAccount(): cannot convert account: " & $$rc.error
  rc.value

proc getAccountProof*(ac: AccountsLedgerRef, address: EthAddress): seq[seq[byte]] =
  let accProof = ac.ledger.proof(address.toAccountKey).valueOr:
    raiseAssert "Failed to get account proof: " & $$error

  accProof[0]

proc getStorageProof*(ac: AccountsLedgerRef, address: EthAddress, slots: openArray[UInt256]): seq[seq[seq[byte]]] =
  var storageProof = newSeqOfCap[seq[seq[byte]]](slots.len)

  let
    addressHash = address.toAccountKey
    accountExists = ac.ledger.hasPath(addressHash).valueOr:
      raiseAssert "Call to hasPath failed: " & $$error

  for slot in slots:
    if not accountExists:
      storageProof.add(@[])
      continue

    let
      slotKey = ac.slots.get(slot).valueOr:
        slot.toBytesBE.keccakHash
      slotProof = ac.ledger.slotProof(addressHash, slotKey).valueOr:
        if error.aErr == FetchPathNotFound:
          storageProof.add(@[])
          continue
        else:
          raiseAssert "Failed to get slot proof: " & $$error
    storageProof.add(slotProof[0])

  storageProof

proc state*(db: ReadOnlyStateDB): KeccakHash {.borrow.}
proc getCodeHash*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, address: EthAddress): UInt256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, address: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, address: EthAddress): CodeBytesRef {.borrow.}
proc getCodeSize*(db: ReadOnlyStateDB, address: EthAddress): int {.borrow.}
proc contractCollision*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc accountExists*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isDeadAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isEmptyAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc getCommittedStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
func inAccessList*(ac: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
func inAccessList*(ac: ReadOnlyStateDB, address: EthAddress, slot: UInt256): bool {.borrow.}
func getTransientStorage*(ac: ReadOnlyStateDB,
                          address: EthAddress, slot: UInt256): UInt256 {.borrow.}
func getAccountProof*(db: ReadOnlyStateDB, eAddr: EthAddress): seq[seq[byte]] {.borrow.}
func getStorageProof*(db: ReadOnlyStateDB, eAddr: EthAddress, slots: openArray[UInt256]): seq[seq[seq[byte]]] {.borrow.}
