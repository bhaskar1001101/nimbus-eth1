# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie traversal
## ====================================
##
## This module provides tools to visit leaf vertices in a monotone order,
## increasing or decreasing. These tools are intended for
## * boundary proof verification
## * step along leaf vertices in sorted order
## * tree/trie consistency checks when debugging
##

{.push raises: [].}

import
  std/[tables, typetraits],
  eth/common,
  results,
  "."/[aristo_desc, aristo_fetch, aristo_get, aristo_hike, aristo_path]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `<=`(a, b: NibblesBuf): bool =
  ## Compare nibbles, different lengths are padded to the right with zeros
  let abMin = min(a.len, b.len)
  for n in 0 ..< abMin:
    if a[n] < b[n]:
      return true
    if b[n] < a[n]:
      return false
    # otherwise a[n] == b[n]

  # Assuming zero for missing entries
  if b.len < a.len:
    for n in abMin + 1 ..< a.len:
      if 0 < a[n]:
        return false
  true

proc `<`(a, b: NibblesBuf): bool =
  not (b <= a)

# ------------------

proc branchNibbleMin*(vtx: VertexRef; minInx: int8): int8 =
  ## Find the least index for an argument branch `vtx` link with index
  ## greater or equal the argument `nibble`.
  if vtx.vType == Branch:
    for n in minInx .. 15:
      if vtx.bVid[n].isValid:
        return n
  -1

proc branchNibbleMax*(vtx: VertexRef; maxInx: int8): int8 =
  ## Find the greatest index for an argument branch `vtx` link with index
  ## less or equal the argument `nibble`.
  if vtx.vType == Branch:
    for n in maxInx.countDown 0:
      if vtx.bVid[n].isValid:
        return n
  -1

# ------------------

proc toLeafTiePayload(hike: Hike): (LeafTie,LeafPayload) =
  ## Shortcut for iterators. This function will gloriously crash unless the
  ## `hike` argument is complete.
  (LeafTie(root: hike.root, path: hike.to(NibblesBuf).pathToTag.value),
   hike.legs[^1].wp.vtx.lData)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc complete(
    hike: Hike;                         # Partially expanded chain of vertices
    vid: VertexID;                      # Start ID
    db: AristoDbRef;                    # Database layer
    hikeLenMax: static[int];            # Beware of loops (if any)
    doLeast: static[bool];              # Direction: *least* or *most*
      ): Result[Hike,(VertexID,AristoError)] =
  ## Extend `hike` using least or last vertex without recursion.
  if not vid.isValid:
    return err((VertexID(0),NearbyVidInvalid))
  var
    vid = vid
    vtx = db.getVtx (hike.root, vid)
    uHike = Hike(root: hike.root, legs: hike.legs)
  if not vtx.isValid:
    return err((vid,GetVtxNotFound))

  while uHike.legs.len < hikeLenMax:
    var leg = Leg(wp: VidVtxPair(vid: vid, vtx: vtx), nibble: -1)
    case vtx.vType:
    of Leaf:
      uHike.legs.add leg
      return ok(uHike) # done

    of Branch:
      when doLeast:
        leg.nibble = vtx.branchNibbleMin 0
      else:
        leg.nibble = vtx.branchNibbleMax 15
      if 0 <= leg.nibble:
        vid = vtx.bVid[leg.nibble]
        vtx = db.getVtx (hike.root, vid)
        if vtx.isValid:
          uHike.legs.add leg
          continue
      return err((leg.wp.vid,NearbyBranchError)) # Oops, no way

  err((VertexID(0),NearbyNestingTooDeep))


proc zeroAdjust(
    hike: Hike;                         # Partially expanded chain of vertices
    db: AristoDbRef;                    # Database layer
    doLeast: static[bool];              # Direction: *least* or *most*
      ): Result[Hike,(VertexID,AristoError)] =
  ## Adjust empty argument path to the first vertex entry to the right. Ths
  ## applies is the argument `hike` is before the first entry in the database.
  ## The result is a hike which is aligned with the first entry.
  proc accept(p: Hike; pfx: NibblesBuf): bool =
    when doLeast:
      p.tail <= pfx
    else:
      pfx <= p.tail

  proc branchBorderNibble(w: VertexRef; n: int8): int8 =
    when doLeast:
      w.branchNibbleMin n
    else:
      w.branchNibbleMax n

  proc toHike(pfx: NibblesBuf, root: VertexID, db: AristoDbRef): Hike =
    when doLeast:
      discard pfx.pathPfxPad(0).hikeUp(root, db, Opt.none(VertexRef), result)
    else:
      discard pfx.pathPfxPad(255).hikeUp(root, db, Opt.none(VertexRef), result)

  if 0 < hike.legs.len:
    return ok(hike)

  let rootVtx = db.getVtx (hike.root, hike.root)
  if rootVtx.isValid:
    block fail:
      var pfx: NibblesBuf
      case rootVtx.vType:
      of Branch:
        # Find first non-dangling link and assign it
        let nibbleID = block:
          when doLeast:
            if hike.tail.len == 0: 0i8
            else: hike.tail[0].int8
          else:
            if hike.tail.len == 0:
              break fail
            hike.tail[0].int8
        let n = rootVtx.branchBorderNibble nibbleID
        if n < 0:
          # Before or after the database range
          return err((hike.root,NearbyBeyondRange))
        pfx = rootVtx.pfx & NibblesBuf.nibble(n.byte)

      of Leaf:
        pfx = rootVtx.pfx
        if not hike.accept pfx:
          # Before or after the database range
          return err((hike.root,NearbyBeyondRange))

        # Pathological case: matching `rootVtx` which is a leaf
        if hike.legs.len == 0 and hike.tail.len == 0:
          var ret =  Hike(root: hike.root)
          ret.legs.add Leg(
              nibble: -1,
              wp:     VidVtxPair(
                vid:  hike.root,
                vtx:  rootVtx))
          return ok ret

      var newHike = pfx.toHike(hike.root, db)
      if 0 < newHike.legs.len:
        return ok(newHike)

  err((VertexID(0),NearbyEmptyHike))


proc finalise(
    hike: Hike;                         # Partially expanded chain of vertices
    db: AristoDbRef;                    # Database layer
    moveRight: static[bool];            # Direction of next vertex
      ): Result[Hike,(VertexID,AristoError)] =
  ## Handle some pathological cases after main processing failed
  proc beyond(p: Hike; pfx: NibblesBuf): bool =
    when moveRight:
      pfx < p.tail
    else:
      p.tail < pfx

  proc branchBorderNibble(w: VertexRef): int8 =
    when moveRight:
      w.branchNibbleMax 15
    else:
      w.branchNibbleMin 0

  # Just for completeness (this case should have been handled, already)
  if hike.legs.len == 0:
    return err((VertexID(0),NearbyEmptyHike))

  # Check whether the path is beyond the database range
  if 0 < hike.tail.len:                 # nothing to compare against, otherwise
    let top = hike.legs[^1]

    # Note that only a `Branch` vertices has a non-zero nibble
    if 0 <= top.nibble and top.nibble == top.wp.vtx.branchBorderNibble:
      # Check the following up vertex
      let
        vid = top.wp.vtx.bVid[top.nibble]
        vtx = db.getVtx (hike.root, vid)
      if not vtx.isValid:
        return err((vid,NearbyDanglingLink))

      let pfx =
        case vtx.vType:
        of Leaf:
          vtx.pfx
        of Branch:
          vtx.pfx & NibblesBuf.nibble(vtx.branchBorderNibble.byte)
      if hike.beyond pfx:
        return err((vid,NearbyBeyondRange))

  # Pathological cases
  # * finalise right: nfffff.. for n < f or
  # * finalise left: n00000.. for 0 < n
  if hike.legs[0].wp.vtx.vType == Branch or
     (1 < hike.legs.len and hike.legs[1].wp.vtx.vType == Branch):
    return err((VertexID(0),NearbyFailed)) # no more vertices

  err((hike.legs[^1].wp.vid,NearbyUnexpectedVtx)) # error


proc nearbyNext(
    hike: Hike;                         # Partially expanded chain of vertices
    db: AristoDbRef;                    # Database layer
    hikeLenMax: static[int];            # Beware of loops (if any)
    moveRight: static[bool];            # Direction of next vertex
      ): Result[Hike,(VertexID,AristoError)] =
  ## Unified implementation of `nearbyRight()` and `nearbyLeft()`.
  proc accept(nibble: int8): bool =
    ## Accept `nibble` unless on boundaty dependent on `moveRight`
    when moveRight:
      nibble < 15
    else:
      0 < nibble

  proc accept(p: Hike; pfx: NibblesBuf): bool =
    when moveRight:
      p.tail <= pfx
    else:
      pfx <= p.tail

  proc branchNibbleNext(w: VertexRef; n: int8): int8 =
    when moveRight:
      w.branchNibbleMin(n + 1)
    else:
      w.branchNibbleMax(n - 1)

  # Some easy cases
  let hike = ? hike.zeroAdjust(db, doLeast=moveRight)

  var
    uHike = hike
    start = true
  while 0 < uHike.legs.len:
    let top = uHike.legs[^1]
    case top.wp.vtx.vType:
    of Leaf:
      return ok(uHike)
    of Branch:
      if top.nibble < 0 or uHike.tail.len == 0:
        return err((top.wp.vid,NearbyUnexpectedVtx))

    var
      step = top
    let
      uHikeLen = uHike.legs.len # in case of backtracking
      uHikeTail = uHike.tail    # in case of backtracking

    # Look ahead checking next vertex
    if start:
      let vid = top.wp.vtx.bVid[top.nibble]
      if not vid.isValid:
        return err((top.wp.vid,NearbyDanglingLink)) # error

      let vtx = db.getVtx (hike.root, vid)
      if not vtx.isValid:
        return err((vid,GetVtxNotFound)) # error

      case vtx.vType
      of Leaf:
        if uHike.accept vtx.pfx:
          return uHike.complete(vid, db, hikeLenMax, doLeast=moveRight)
      of Branch:
        let nibble = uHike.tail[0].int8
        if start and accept nibble:
          # Step down and complete with a branch link on the child vertex
          step = Leg(wp: VidVtxPair(vid: vid, vtx: vtx), nibble: nibble)
          uHike.legs.add step

    # Find the next item to the right/left of the current top entry
    let n = step.wp.vtx.branchNibbleNext step.nibble
    if 0 <= n:
      uHike.legs[^1].nibble = n
      return uHike.complete(
        step.wp.vtx.bVid[n], db, hikeLenMax, doLeast=moveRight)

    if start:
      # Retry without look ahead
      start = false

      # Restore `uPath` (pop temporary extra step)
      if uHikeLen < uHike.legs.len:
        uHike.legs.setLen(uHikeLen)
        uHike.tail = uHikeTail
    else:
      # Pop current `Branch` vertex on top and append nibble to `tail`
      uHike.tail = NibblesBuf.nibble(top.nibble.byte) & uHike.tail
      uHike.legs.setLen(uHike.legs.len - 1)
    # End while

  # Handle some pathological cases
  hike.finalise(db, moveRight)

proc nearbyNextLeafTie(
    lty: LeafTie;                       # Some `Patricia Trie` path
    db: AristoDbRef;                    # Database layer
    hikeLenMax: static[int];            # Beware of loops (if any)
    moveRight:static[bool];             # Direction of next vertex
      ): Result[PathID,(VertexID,AristoError)] =
  ## Variant of `nearbyNext()`, convenience wrapper
  var hike: Hike
  discard lty.hikeUp(db, Opt.none(VertexRef), hike)
  hike = ?hike.nearbyNext(db, hikeLenMax, moveRight)

  if 0 < hike.legs.len:
    if hike.legs[^1].wp.vtx.vType != Leaf:
      return err((hike.legs[^1].wp.vid,NearbyLeafExpected))
    let rc = hike.legsTo(NibblesBuf).pathToTag
    if rc.isOk:
      return ok rc.value
    return err((VertexID(0),rc.error))

  err((VertexID(0),NearbyLeafExpected))

# ------------------------------------------------------------------------------
# Public functions, moving and right boundary proof
# ------------------------------------------------------------------------------

proc right*(
    hike: Hike;                         # Partially expanded chain of vertices
    db: AristoDbRef;                    # Database layer
      ): Result[Hike,(VertexID,AristoError)] =
  ## Extends the maximally extended argument vertices `hike` to the right (i.e.
  ## with non-decreasing path value). This function does not backtrack if
  ## there are dangling links in between. It will return an error in that case.
  ##
  ## If there is no more leaf vertices to the right of the argument `hike`, the
  ## particular error code `NearbyBeyondRange` is returned.
  ##
  ## This code is intended to be used for verifying a left-bound proof to
  ## verify that there is no leaf vertex *right* of a boundary path value.
  hike.nearbyNext(db, 64, moveRight=true)

proc right*(
    lty: LeafTie;                       # Some `Patricia Trie` path
    db: AristoDbRef;                    # Database layer
      ): Result[LeafTie,(VertexID,AristoError)] =
  ## Variant of `nearbyRight()` working with a `LeafTie` argument instead
  ## of a `Hike`.
  ok LeafTie(
    root: lty.root,
    path: ? lty.nearbyNextLeafTie(db, 64, moveRight=true))

iterator rightPairs*(
    db: AristoDbRef;                    # Database layer
    start = low(LeafTie);               # Before or at first value
      ): (LeafTie,LeafPayload) =
  ## Traverse the sub-trie implied by the argument `start` with increasing
  ## order.
  var hike: Hike
  discard start.hikeUp(db, Opt.none(VertexRef), hike)
  var rc = hike.right db
  while rc.isOK:
    hike = rc.value
    let (key, pyl) = hike.toLeafTiePayload
    yield (key, pyl)
    if high(PathID) <= key.path:
      break

    # Increment `key` by one and update `hike`. In many cases, the current
    # `hike` can be modified and re-used which saves some database lookups.
    block reuseHike:
      let tail = hike.legs[^1].wp.vtx.pfx
      if 0 < tail.len:
        let topNibble = tail[tail.len - 1]
        if topNibble < 15:
          let newNibble = NibblesBuf.nibble(topNibble+1)
          hike.tail = tail.slice(0, tail.len - 1) & newNibble
          hike.legs.setLen(hike.legs.len - 1)
          break reuseHike
      if 1 < tail.len:
        let nxtNibble = tail[tail.len - 2]
        if nxtNibble < 15:
          let dblNibble = NibblesBuf.fromBytes([((nxtNibble+1) shl 4) + 0])
          hike.tail = tail.slice(0, tail.len - 2) & dblNibble
          hike.legs.setLen(hike.legs.len - 1)
          break reuseHike
      # Fall back to default method
      discard key.next.hikeUp(db, Opt.none(VertexRef), hike)

    rc = hike.right db
    # End while

iterator rightPairsAccount*(
    db: AristoDbRef;                    # Database layer
    start = low(PathID);                # Before or at first value
      ): (PathID,AristoAccount) =
  ## Variant of `rightPairs()` for accounts tree
  for (lty,pyl) in db.rightPairs LeafTie(root: VertexID(1), path: start):
    yield (lty.path, pyl.account)

iterator rightPairsGeneric*(
    db: AristoDbRef;                    # Database layer
    root: VertexID;                     # Generic root (different from VertexID)
    start = low(PathID);                # Before or at first value
      ): (PathID,Blob) =
  ## Variant of `rightPairs()` for a generic tree
  # Verify that `root` is neither from an accounts tree nor a strorage tree.
  if VertexID(1) < root and root.distinctBase < LEAST_FREE_VID:
    for (lty,pyl) in db.rightPairs LeafTie(root: VertexID(1), path: start):
        yield (lty.path, pyl.rawBlob)

iterator rightPairsStorage*(
    db: AristoDbRef;                    # Database layer
    accPath: Hash256;           # Account the storage data belong to
    start = low(PathID);                # Before or at first value
      ): (PathID,UInt256) =
  ## Variant of `rightPairs()` for a storage tree
  block body:
    let stoID = db.fetchStorageID(accPath).valueOr:
      break body
    if stoID.isValid:
      for (lty,pyl) in db.rightPairs LeafTie(root: stoID, path: start):
        yield (lty.path, pyl.stoData)

# ----------------

proc left*(
    hike: Hike;                         # Partially expanded chain of vertices
    db: AristoDbRef;                    # Database layer
      ): Result[Hike,(VertexID,AristoError)] =
  ## Similar to `nearbyRight()`.
  ##
  ## This code is intended to be used for verifying a right-bound proof to
  ## verify that there is no leaf vertex *left* to a boundary path value.
  hike.nearbyNext(db, 64, moveRight=false)

proc left*(
    lty: LeafTie;                       # Some `Patricia Trie` path
    db: AristoDbRef;                    # Database layer
      ): Result[LeafTie,(VertexID,AristoError)] =
  ## Similar to `nearbyRight()` for `LeafTie` argument instead of a `Hike`.
  ok LeafTie(
    root: lty.root,
    path: ? lty.nearbyNextLeafTie(db, 64, moveRight=false))

iterator leftPairs*(
    db: AristoDbRef;                    # Database layer
    start = high(LeafTie);              # Before or at first value
      ): (LeafTie,LeafPayload) =
  ## Traverse the sub-trie implied by the argument `start` with decreasing
  ## order. It will stop at any error. In order to reproduce an error, one
  ## can run the function `left()` on the last returned `LiefTie` item with
  ## the `path` field decremented by `1`.
  var
    hike: Hike
  discard start.hikeUp(db, Opt.none(VertexRef), hike)

  var rc = hike.left db
  while rc.isOK:
    hike = rc.value
    let (key, pyl) = hike.toLeafTiePayload
    yield (key, pyl)
    if key.path <= low(PathID):
      break

    # Decrement `key` by one and update `hike`. In many cases, the current
    # `hike` can be modified and re-used which saves some database lookups.
    block reuseHike:
      let tail = hike.legs[^1].wp.vtx.pfx
      if 0 < tail.len:
        let topNibble = tail[tail.len - 1]
        if 0 < topNibble:
          let newNibble = NibblesBuf.nibble(topNibble - 1)
          hike.tail = tail.slice(0, tail.len - 1) & newNibble
          hike.legs.setLen(hike.legs.len - 1)
          break reuseHike
      if 1 < tail.len:
        let nxtNibble = tail[tail.len - 2]
        if 0 < nxtNibble:
          let dblNibble = NibblesBuf.fromBytes([((nxtNibble-1) shl 4) + 15])
          hike.tail = tail.slice(0, tail.len - 2) & dblNibble
          hike.legs.setLen(hike.legs.len - 1)
          break reuseHike
      # Fall back to default method
      discard key.prev.hikeUp(db, Opt.none(VertexRef), hike)

    rc = hike.left db
    # End while

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc rightMissing*(
    hike: Hike;                         # Partially expanded chain of vertices
    db: AristoDbRef;                    # Database layer
      ): Result[bool,AristoError] =
  ## Returns `true` if the maximally extended argument vertex `hike` is the
  ## right most on the hexary trie database. It verifies that there is no more
  ## leaf entry to the right of the argument `hike`. This function is an
  ## alternative to
  ## ::
  ##   let rc = path.nearbyRight(db)
  ##   if rc.isOk:
  ##     # not at the end => false
  ##     ...
  ##   elif rc.error != NearbyBeyondRange:
  ##     # problem with database => error
  ##     ...
  ##   else:
  ##     # no nore vertices => true
  ##     ...
  ## and is intended mainly for debugging.
  if hike.legs.len == 0:
    return err(NearbyEmptyHike)
  if 0 < hike.tail.len:
    return err(NearbyPathTailUnexpected)

  let top = hike.legs[^1]
  if top.wp.vtx.vType != Branch or top.nibble < 0:
    return err(NearbyBranchError)

  let vid = top.wp.vtx.bVid[top.nibble]
  if not vid.isValid:
    return err(NearbyDanglingLink) # error

  let vtx = db.getVtx (hike.root, vid)
  if not vtx.isValid:
    return err(GetVtxNotFound) # error

  case vtx.vType
  of Leaf:
    return ok(vtx.pfx < hike.tail)
  of Branch:
    return ok(vtx.branchNibbleMin(hike.tail[0].int8) < 0)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
