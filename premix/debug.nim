# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, os, strutils],
  stew/byteutils,
  chronicles,
  results,
  ../nimbus/[evm/state, evm/types],
  ../nimbus/core/executor,
  ./premixcore, ./prestate,
  ../nimbus/tracer,
  ../nimbus/common/common

proc prepareBlockEnv(node: JsonNode, memoryDB: CoreDbRef) =
  let state = node["state"]
  let kvt = memoryDB.ctx.getKvt()
  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    kvt.put(key, value).isOkOr:
      raiseAssert "prepareBlockEnv(): put() (loop) failed " & $$error

proc executeBlock(blockEnv: JsonNode, memoryDB: CoreDbRef, blockNumber: BlockNumber) =
  var
    parentNumber = blockNumber - 1
    com = CommonRef.new(memoryDB)
    parent = com.db.getBlockHeader(parentNumber)
    blk = com.db.getEthBlock(blockNumber)
  let transaction = memoryDB.ctx.newTransaction()
  defer: transaction.dispose()

  let
    vmState = BaseVMState.new(parent, blk.header, com)
    validationResult = vmState.processBlock(blk)

  if validationResult.isErr:
    error "block validation error", err = validationResult.error()
  else:
    info "block validation success", blockNumber

  transaction.rollback()
  vmState.dumpDebuggingMetaData(blk, false)
  let
    fileName = "debug" & $blockNumber & ".json"
    nimbus   = json.parseFile(fileName)
    geth     = blockEnv["geth"]

  processNimbusData(nimbus)

  # premix data goes to report page
  generatePremixData(nimbus, geth)

  # prestate data goes to debug tool and contains data
  # needed to execute single block
  generatePrestate(nimbus, geth, blockNumber, parent, blk)

proc main() =
  if paramCount() == 0:
    echo "usage: debug blockxxx.json"
    quit(QuitFailure)

  let
    blockEnv = json.parseFile(paramStr(1))
    memoryDB = newCoreDbRef(DefaultDbMemory)
    blockNumberHex = blockEnv["blockNumber"].getStr()
    blockNumber = parseHexInt(blockNumberHex).uint64

  prepareBlockEnv(blockEnv, memoryDB)
  executeBlock(blockEnv, memoryDB, blockNumber)

main()
