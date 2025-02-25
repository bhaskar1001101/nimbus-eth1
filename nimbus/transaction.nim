# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./constants, ./errors, eth/[common, keys], ./utils/utils,
  common/evmforks, ./evm/internals

import eth/common/transaction as common_transaction
export common_transaction, errors

proc toWordSize(size: GasInt): GasInt =
  # Round input to the nearest bigger multiple of 32
  # tx validation will ensure the value is not too big
  if size > GasInt.high-31:
    return (GasInt.high shr 5) + 1

  (size + 31) shr 5

func intrinsicGas*(data: openArray[byte], fork: EVMFork): GasInt =
  result = GasInt(gasFees[fork][GasTransaction])
  for i in data:
    if i == 0:
      result += GasInt(gasFees[fork][GasTXDataZero])
    else:
      result += GasInt(gasFees[fork][GasTXDataNonZero])

proc intrinsicGas*(tx: Transaction, fork: EVMFork): GasInt =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  result = tx.payload.intrinsicGas(fork)

  if tx.contractCreation:
    result += GasInt(gasFees[fork][GasTXCreate])
    if fork >= FkShanghai:
      # cannot use wordCount here, it will raise unlisted exception
      let numWords = toWordSize(GasInt tx.payload.len)
      result += GasInt(gasFees[fork][GasInitcodeWord]) * numWords

  if tx.txType > TxLegacy:
    result += GasInt(tx.accessList.len) * ACCESS_LIST_ADDRESS_COST
    var numKeys = 0
    for n in tx.accessList:
      inc(numKeys, n.storageKeys.len)
    result += GasInt(numKeys) * ACCESS_LIST_STORAGE_KEY_COST

proc getSignature*(tx: Transaction, output: var Signature): bool =
  var bytes: array[65, byte]
  bytes[0..31] = tx.R.toBytesBE()
  bytes[32..63] = tx.S.toBytesBE()

  if tx.txType == TxLegacy:
    var v = tx.V
    if v >= EIP155_CHAIN_ID_OFFSET:
      v = 28 - (v and 0x01)
    elif v == 27 or v == 28:
      discard
    else:
      return false
    bytes[64] = byte(v - 27)
  else:
    bytes[64] = tx.V.byte

  let sig = Signature.fromRaw(bytes)
  if sig.isOk:
    output = sig[]
    return true
  return false

proc toSignature*(tx: Transaction): Signature =
  if not getSignature(tx, result):
    raise newException(Exception, "Invalid signature")

proc getSender*(tx: Transaction, output: var EthAddress): bool =
  ## Find the address the transaction was sent from.
  var sig: Signature
  if tx.getSignature(sig):
    var txHash = tx.txHashNoSignature
    let pubkey = recover(sig, SkMessage(txHash.data))
    if pubkey.isOk:
      output = pubkey[].toCanonicalAddress()
      result = true

proc getSender*(tx: Transaction): EthAddress =
  ## Raises error on failure to recover public key
  if not tx.getSender(result):
    raise newException(ValidationError, "Could not derive sender address from transaction")

proc getRecipient*(tx: Transaction, sender: EthAddress): EthAddress =
  if tx.contractCreation:
    result = generateAddress(sender, tx.nonce)
  else:
    result = tx.to.get()

proc validateTxLegacy(tx: Transaction, fork: EVMFork) =
  var
    vMin = 27'u64
    vMax = 28'u64

  if tx.V >= EIP155_CHAIN_ID_OFFSET:
    let chainId = (tx.V - EIP155_CHAIN_ID_OFFSET) div 2
    vMin = 35 + (2 * chainId)
    vMax = vMin + 1

  var isValid = tx.R >= UInt256.one
  isValid = isValid and tx.S >= UInt256.one
  isValid = isValid and tx.V >= vMin
  isValid = isValid and tx.V <= vMax
  isValid = isValid and tx.S < SECPK1_N
  isValid = isValid and tx.R < SECPK1_N

  if fork >= FkHomestead:
    isValid = isValid and tx.S < SECPK1_N div 2

  if not isValid:
    raise newException(ValidationError, "Invalid legacy transaction")

proc validateTxEip2930(tx: Transaction) =
  var isValid = tx.V == 0'u64 or tx.V == 1'u64
  isValid = isValid and tx.S >= UInt256.one
  isValid = isValid and tx.S < SECPK1_N
  isValid = isValid and tx.R < SECPK1_N

  if not isValid:
    raise newException(ValidationError, "Invalid typed transaction")

proc validateTxEip4844(tx: Transaction) =
  validateTxEip2930(tx)

  var isValid = tx.payload.len <= MAX_CALLDATA_SIZE
  isValid = isValid and tx.accessList.len <= MAX_ACCESS_LIST_SIZE

  for acl in tx.accessList:
    isValid = isValid and
      (acl.storageKeys.len <= MAX_ACCESS_LIST_STORAGE_KEYS)

  isValid = isValid and
    tx.versionedHashes.len <= MAX_BLOBS_PER_BLOCK

  for bv in tx.versionedHashes:
    isValid = isValid and
      bv.data[0] == VERSIONED_HASH_VERSION_KZG

  if not isValid:
    raise newException(ValidationError, "Invalid EIP-4844 transaction")

proc validateTxEip7702(tx: Transaction) =
  validateTxEip2930(tx)

  if tx.authorizationList.len == 0:
    raise newException(ValidationError, "Invalid EIP-7702 transaction")

proc validate*(tx: Transaction, fork: EVMFork) =
  # parameters pass validation rules
  if tx.intrinsicGas(fork) > tx.gasLimit:
    raise newException(ValidationError, "Insufficient gas")

  if fork >= FkShanghai and tx.contractCreation and tx.payload.len > EIP3860_MAX_INITCODE_SIZE:
    raise newException(ValidationError, "Initcode size exceeds max")

  # check signature validity
  var sender: EthAddress
  if not tx.getSender(sender):
    raise newException(ValidationError, "Invalid signature or failed message verification")

  case tx.txType
  of TxLegacy:
    validateTxLegacy(tx, fork)
  of TxEip4844:
    validateTxEip4844(tx)
  of TxEip2930, TxEip1559:
    validateTxEip2930(tx)
  of TxEip7702:
    validateTxEip7702(tx)

proc signTransaction*(tx: Transaction, privateKey: PrivateKey, chainId: ChainId, eip155: bool): Transaction =
  result = tx
  if eip155:
    # trigger rlpEncodeEIP155 in nim-eth
    result.V = chainId.uint64 * 2'u64 + 35'u64

  let
    rlpTx = rlpEncode(result)
    sig = sign(privateKey, rlpTx).toRaw

  case tx.txType
  of TxLegacy:
    if eip155:
      result.V = sig[64].uint64 + result.V
    else:
      result.V = sig[64].uint64 + 27'u64
  else:
    result.V = sig[64].uint64

  result.R = UInt256.fromBytesBE(sig[0..31])
  result.S = UInt256.fromBytesBE(sig[32..63])

# deriveChainId derives the chain id from the given v parameter
func deriveChainId*(v: uint64, chainId: ChainId): ChainId =
  if v == 27 or v == 28:
    chainId
  else:
    ((v - 35) div 2).ChainId

func validateChainId*(tx: Transaction, chainId: ChainId): bool =
  if tx.txType == TxLegacy:
    chainId.uint64 == deriveChainId(tx.V, chainId).uint64
  else:
    chainId.uint64 == tx.chainId.uint64

func eip1559TxNormalization*(tx: Transaction;
                             baseFeePerGas: GasInt): Transaction =
  ## This function adjusts a legacy transaction to EIP-1559 standard. This
  ## is needed particularly when using the `validateTransaction()` utility
  ## with legacy transactions.
  result = tx
  if tx.txType < TxEip1559:
    result.maxPriorityFeePerGas = tx.gasPrice
    result.maxFeePerGas = tx.gasPrice
  else:
    result.gasPrice = baseFeePerGas +
      min(result.maxPriorityFeePerGas, result.maxFeePerGas - baseFeePerGas)

func maxPriorityFeePerGasNorm*(tx: Transaction): GasInt =
  if tx.txType < TxEip1559:
    tx.gasPrice
  else:
    tx.maxPriorityFeePerGas

func maxFeePerGasNorm*(tx: Transaction): GasInt =
  if tx.txType < TxEip1559:
    tx.gasPrice
  else:
    tx.maxFeePerGas

func effectiveGasPrice*(tx: Transaction, baseFeePerGas: GasInt): GasInt =
  if tx.txType < TxEip1559:
    tx.gasPrice
  else:
    baseFeePerGas +
      min(tx.maxPriorityFeePerGas, tx.maxFeePerGas - baseFeePerGas)

func effectiveGasTip*(tx: Transaction; baseFeePerGas: Opt[UInt256]): GasInt =
  let
    baseFeePerGas = baseFeePerGas.get(0.u256).truncate(GasInt)

  min(tx.maxPriorityFeePerGasNorm(), tx.maxFeePerGasNorm() - baseFeePerGas)

proc decodeTx*(bytes: openArray[byte]): Transaction =
  var rlp = rlpFromBytes(bytes)
  result = rlp.read(Transaction)
  if rlp.hasData:
    raise newException(RlpError, "rlp: input contains more than one value")

proc decodePooledTx*(bytes: openArray[byte]): PooledTransaction =
  var rlp = rlpFromBytes(bytes)
  result = rlp.read(PooledTransaction)
  if rlp.hasData:
    raise newException(RlpError, "rlp: input contains more than one value")
