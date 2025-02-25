# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Rocks DB store data record
## ==========================

{.push raises: [].}

import
  eth/common,
  rocksdb,
  results,
  ../../[aristo_blobify, aristo_desc],
  ../init_common,
  ./rdb_desc

const
  extraTraceMessages = false
    ## Enable additional logging noise

when extraTraceMessages:
  import chronicles

  logScope:
    topics = "aristo-rocksdb"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc disposeSession(rdb: var RdbInst) =
  rdb.session.close()
  rdb.session = WriteBatchRef(nil)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc begin*(rdb: var RdbInst) =
  if rdb.session.isNil:
    rdb.session = rdb.baseDb.openWriteBatch()

proc rollback*(rdb: var RdbInst) =
  if not rdb.session.isClosed():
    rdb.rdKeyLru = typeof(rdb.rdKeyLru).init(rdb.rdKeySize)
    rdb.rdVtxLru = typeof(rdb.rdVtxLru).init(rdb.rdVtxSize)
    rdb.disposeSession()

proc commit*(rdb: var RdbInst): Result[void,(AristoError,string)] =
  if not rdb.session.isClosed():
    defer: rdb.disposeSession()
    rdb.baseDb.write(rdb.session).isOkOr:
      const errSym = RdbBeDriverWriteError
      when extraTraceMessages:
        trace logTxt "commit", error=errSym, info=error
      return err((errSym,error))
  ok()


proc putAdm*(
    rdb: var RdbInst;
    xid: AdminTabID;
    data: openArray[byte];
      ): Result[void,(AdminTabID,AristoError,string)] =
  let dsc = rdb.session
  if data.len == 0:
    dsc.delete(xid.toOpenArray, rdb.admCol.handle()).isOkOr:
      const errSym = RdbBeDriverDelAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((xid,errSym,error))
  else:
    dsc.put(xid.toOpenArray, data, rdb.admCol.handle()).isOkOr:
      const errSym = RdbBeDriverPutAdmError
      when extraTraceMessages:
        trace logTxt "putAdm()", xid, error=errSym, info=error
      return err((xid,errSym,error))
  ok()

proc putKey*(
    rdb: var RdbInst;
    rvid: RootedVertexID, key: HashKey;
      ): Result[void,(VertexID,AristoError,string)] =
  let dsc = rdb.session
  # We only write keys whose value has to be hashed - the trivial ones can be
  # loaded from the corresponding vertex directly!
  # TODO move this logic to a higher layer
  # TODO skip the delete for trivial keys - it's here to support databases that
  #      were written at a time when trivial keys were also cached - it should
  #      be cleaned up when revising the key cache in general.
  if key.isValid and key.len == 32:
    dsc.put(rvid.blobify().data(), key.data, rdb.keyCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdKeyLru` cache
      const errSym = RdbBeDriverPutKeyError
      when extraTraceMessages:
        trace logTxt "putKey()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update existing cached items but don't add new ones since doing so is
    # likely to evict more useful items (when putting many items, we might even
    # evict those that were just added)
    discard rdb.rdKeyLru.update(rvid.vid, key)

  else:
    dsc.delete(rvid.blobify().data(), rdb.keyCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdKeyLru` cache
      const errSym = RdbBeDriverDelKeyError
      when extraTraceMessages:
        trace logTxt "putKey()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update cache, vertex will most probably never be visited anymore
    rdb.rdKeyLru.del rvid.vid

  ok()


proc putVtx*(
    rdb: var RdbInst;
    rvid: RootedVertexID; vtx: VertexRef
      ): Result[void,(VertexID,AristoError,string)] =
  let dsc = rdb.session
  if vtx.isValid:
    dsc.put(rvid.blobify().data(), vtx.blobify(), rdb.vtxCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdVtxLru` cache
      const errSym = RdbBeDriverPutVtxError
      when extraTraceMessages:
        trace logTxt "putVtx()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update existing cached items but don't add new ones since doing so is
    # likely to evict more useful items (when putting many items, we might even
    # evict those that were just added)
    discard rdb.rdVtxLru.update(rvid.vid, vtx)

  else:
    dsc.delete(rvid.blobify().data(), rdb.vtxCol.handle()).isOkOr:
      # Caller must `rollback()` which will flush the `rdVtxLru` cache
      const errSym = RdbBeDriverDelVtxError
      when extraTraceMessages:
        trace logTxt "putVtx()", vid, error=errSym, info=error
      return err((rvid.vid,errSym,error))

    # Update cache, vertex will most probably never be visited anymore
    rdb.rdVtxLru.del rvid.vid

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
