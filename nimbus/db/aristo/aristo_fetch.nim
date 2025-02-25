# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Obects Retrival Via Traversal Path
## ===============================================
##
{.push raises: [].}

import
  std/typetraits,
  eth/common,
  results,
  "."/[aristo_compute, aristo_desc, aristo_get, aristo_layers, aristo_hike]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func mustBeGeneric(
    root: VertexID;
      ): Result[void,AristoError] =
  ## Verify that `root` is neither from an accounts tree nor a strorage tree.
  if not root.isValid:
    return err(FetchRootVidMissing)
  elif root == VertexID(1):
    return err(FetchAccRootNotAccepted)
  elif LEAST_FREE_VID <= root.distinctBase:
    return err(FetchStoRootNotAccepted)
  ok()

proc retrieveLeaf(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[VertexRef,AristoError] =
  if path.len == 0:
    return err(FetchPathInvalid)

  for step in stepUp(NibblesBuf.fromBytes(path), root, db):
    let vtx = step.valueOr:
      if error in HikeAcceptableStopsNotFound:
        return err(FetchPathNotFound)
      return err(error)

    if vtx.vType == Leaf:
      return ok vtx

  return err(FetchPathNotFound)

proc cachedAccLeaf*(db: AristoDbRef; accPath: Hash256): Opt[VertexRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetAccLeaf(accPath) or
    db.accLeaves.get(accPath) or
    Opt.none(VertexRef)

proc cachedStoLeaf*(db: AristoDbRef; mixPath: Hash256): Opt[VertexRef] =
  # Return vertex from layers or cache, `nil` if it's known to not exist and
  # none otherwise
  db.layersGetStoLeaf(mixPath) or
    db.stoLeaves.get(mixPath) or
    Opt.none(VertexRef)

proc retrieveAccountLeaf(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[VertexRef,AristoError] =
  if (let leafVtx = db.cachedAccLeaf(accPath); leafVtx.isSome()):
    if not leafVtx[].isValid():
      return err(FetchPathNotFound)
    return ok leafVtx[]

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database
  let
    leafVtx = db.retrieveLeaf(VertexID(1), accPath.data).valueOr:
      if error == FetchPathNotFound:
        db.accLeaves.put(accPath, nil)
      return err(error)

  db.accLeaves.put(accPath, leafVtx)

  ok leafVtx

proc retrieveMerkleHash(
    db: AristoDbRef;
    root: VertexID;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  let key =
    if updateOk:
      db.computeKey((root, root)).valueOr:
        if error == GetVtxNotFound:
          return ok(EMPTY_ROOT_HASH)
        return err(error)
    else:
      let (key, _) = db.getKeyRc((root, root)).valueOr:
        if error == GetKeyNotFound:
          return ok(EMPTY_ROOT_HASH) # empty sub-tree
        return err(error)
      key
  ok key.to(Hash256)


proc hasPayload(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[bool,AristoError] =
  let error = db.retrieveLeaf(root, path).errorOr:
    return ok(true)

  if error == FetchPathNotFound:
    return ok(false)
  err(error)

proc hasAccountPayload(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[bool,AristoError] =
  let error = db.retrieveAccountLeaf(accPath).errorOr:
    return ok(true)

  if error == FetchPathNotFound:
    return ok(false)
  err(error)

proc fetchStorageIdImpl(
    db: AristoDbRef;
    accPath: Hash256;
    enaStoRootMissing = false;
      ): Result[VertexID,AristoError] =
  ## Helper function for retrieving a storage (vertex) ID for a given account.
  let
    leafVtx = ?db.retrieveAccountLeaf(accPath)
    stoID = leafVtx[].lData.stoID

  if stoID.isValid:
    ok stoID.vid
  elif enaStoRootMissing:
    err(FetchPathStoRootMissing)
  else:
    err(FetchPathNotFound)

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc fetchAccountHike*(
    db: AristoDbRef;                   # Database
    accPath: Hash256;                  # Implies a storage ID (if any)
    accHike: var Hike
      ): Result[void,AristoError] =
  ## Expand account path to account leaf or return failure

  # Prefer the leaf cache so as not to burden the lower layers
  let leaf = db.cachedAccLeaf(accPath)
  if leaf == Opt.some(VertexRef(nil)):
    return err(FetchAccInaccessible)

  accPath.hikeUp(VertexID(1), db, leaf, accHike).isOkOr:
    return err(FetchAccInaccessible)

  # Extract the account payload from the leaf
  if accHike.legs.len == 0 or accHike.legs[^1].wp.vtx.vType != Leaf:
    return err(FetchAccPathWithoutLeaf)

  assert accHike.legs[^1].wp.vtx.lData.pType == AccountData

  ok()

proc fetchStorageID*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[VertexID,AristoError] =
  ## Public helper function for retrieving a storage (vertex) ID for a given account. This
  ## function returns a separate error `FetchPathStoRootMissing` (from `FetchPathNotFound`)
  ## if the account for the argument path `accPath` exists but has no storage root.
  ##
  db.fetchStorageIdImpl(accPath, enaStoRootMissing=true)

proc retrieveStoragePayload(
    db: AristoDbRef;
    accPath: Hash256;
    stoPath: Hash256;
      ): Result[UInt256,AristoError] =
  let mixPath = mixUp(accPath, stoPath)

  if (let leafVtx = db.cachedStoLeaf(mixPath); leafVtx.isSome()):
    if not leafVtx[].isValid():
      return err(FetchPathNotFound)
    return ok leafVtx[].lData.stoData

  # Updated payloads are stored in the layers so if we didn't find them there,
  # it must have been in the database
  let leafVtx = db.retrieveLeaf(? db.fetchStorageIdImpl(accPath), stoPath.data).valueOr:
    if error == FetchPathNotFound:
      db.stoLeaves.put(mixPath, nil)
    return err(error)

  db.stoLeaves.put(mixPath, leafVtx)

  ok leafVtx.lData.stoData

proc hasStoragePayload(
    db: AristoDbRef;
    accPath: Hash256;
    stoPath: Hash256;
      ): Result[bool,AristoError] =
  let error = db.retrieveStoragePayload(accPath, stoPath).errorOr:
    return ok(true)

  if error == FetchPathNotFound:
    return ok(false)
  err(error)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchLastSavedState*(
    db: AristoDbRef;
      ): Result[SavedState,AristoError] =
  ## Wrapper around `getLstUbe()`. The function returns the state of the last
  ## saved state. This is a Merkle hash tag for vertex with ID 1 and a bespoke
  ## `uint64` identifier (may be interpreted as block number.)
  db.getLstUbe()

proc fetchAccountRecord*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[AristoAccount,AristoError] =
  ## Fetch an account record from the database indexed by `accPath`.
  ##
  let leafVtx = ? db.retrieveAccountLeaf(accPath)
  assert leafVtx.lData.pType == AccountData   # debugging only

  ok leafVtx.lData.account

proc fetchAccountState*(
    db: AristoDbRef;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  ## Fetch the Merkle hash of the account root.
  db.retrieveMerkleHash(VertexID(1), updateOk)

proc hasPathAccount*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[bool,AristoError] =
  ## For an account record indexed by `accPath` query whether this record exists
  ## on the database.
  ##
  db.hasAccountPayload(accPath)

proc fetchGenericData*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[Blob,AristoError] =
  ## For a generic sub-tree starting at `root`, fetch the data record
  ## indexed by `path`.
  ##
  ? root.mustBeGeneric()
  let pyl = ? db.retrieveLeaf(root, path)
  assert pyl.lData.pType == RawData   # debugging only
  ok pyl.lData.rawBlob

proc fetchGenericState*(
    db: AristoDbRef;
    root: VertexID;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  ## Fetch the Merkle hash of the argument `root`.
  db.retrieveMerkleHash(root, updateOk)

proc hasPathGeneric*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
      ): Result[bool,AristoError] =
  ## For a generic sub-tree starting at `root` and indexed by `path`, query
  ## whether this record exists on the database.
  ##
  ? root.mustBeGeneric()
  db.hasPayload(root, path)

proc fetchStorageData*(
    db: AristoDbRef;
    accPath: Hash256;
    stoPath: Hash256;
      ): Result[UInt256,AristoError] =
  ## For a storage tree related to account `accPath`, fetch the data record
  ## from the database indexed by `path`.
  ##
  db.retrieveStoragePayload(accPath, stoPath)

proc fetchStorageState*(
    db: AristoDbRef;
    accPath: Hash256;
    updateOk: bool;
      ): Result[Hash256,AristoError] =
  ## Fetch the Merkle hash of the storage root related to `accPath`.
  let stoID = db.fetchStorageIdImpl(accPath).valueOr:
    if error == FetchPathNotFound:
      return ok(EMPTY_ROOT_HASH) # no sub-tree
    return err(error)
  db.retrieveMerkleHash(stoID, updateOk)

proc hasPathStorage*(
    db: AristoDbRef;
    accPath: Hash256;
    stoPath: Hash256;
      ): Result[bool,AristoError] =
  ## For a storage tree related to account `accPath`, query whether the data
  ## record indexed by `path` exists on the database.
  ##
  db.hasStoragePayload(accPath, stoPath)

proc hasStorageData*(
    db: AristoDbRef;
    accPath: Hash256;
      ): Result[bool,AristoError] =
  ## For a storage tree related to account `accPath`, query whether there
  ## is a non-empty data storage area at all.
  ##
  let stoID = db.fetchStorageIdImpl(accPath).valueOr:
    if error == FetchPathNotFound:
      return ok(false) # no sub-tree
    return err(error)
  ok stoID.isValid

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
