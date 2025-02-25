# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/os,
  eth/keys,
  eth/p2p as eth_p2p,
  chronos,
  json_rpc/[rpcserver, rpcclient],
  results,
  ../../../nimbus/[
    config,
    constants,
    core/chain,
    core/tx_pool,
    core/tx_pool/tx_item,
    core/block_import,
    rpc,
    sync/protocol,
    sync/beacon,
    sync/handlers,
    beacon/beacon_engine,
    beacon/web3_eth_conv,
    common
  ],
  ../../../tests/test_helpers,
  web3/execution_types

from ./node import setBlock

export
  results

type
  EngineEnv* = ref object
    conf   : NimbusConf
    com    : CommonRef
    node   : EthereumNode
    server : RpcHttpServer
    ttd    : DifficultyInt
    client : RpcHttpClient
    sync   : BeaconSyncRef
    txPool : TxPoolRef
    chain  : ForkedChainRef

const
  baseFolder  = "hive_integration/nodocker/engine"
  genesisFile = baseFolder & "/init/genesis.json"
  sealerKey   = baseFolder & "/init/sealer.key"
  chainFolder = baseFolder & "/chains"
  jwtSecret   = "0x7365637265747365637265747365637265747365637265747365637265747365"

proc makeCom*(conf: NimbusConf): CommonRef =
  CommonRef.new(
    newCoreDbRef DefaultDbMemory,
    conf.networkId,
    conf.networkParams
  )

proc envConfig*(): NimbusConf =
  makeConfig(@[
    "--custom-network:" & genesisFile,
    "--listen-address: 127.0.0.1",
  ])

proc envConfig*(conf: ChainConfig): NimbusConf =
  result = envConfig()
  result.networkParams.config = conf

proc newEngineEnv*(conf: var NimbusConf, chainFile: string, enableAuth: bool): EngineEnv =
  if chainFile.len > 0:
    # disable clique if we are using PoW chain
    conf.networkParams.config.consensusType = ConsensusType.POW

  let ctx = newEthContext()
  ctx.am.importPrivateKey(sealerKey).isOkOr:
    echo error
    quit(QuitFailure)

  let
    node  = setupEthNode(conf, ctx)
    com   = makeCom(conf)
    head  = com.db.getCanonicalHead()
    chain = newForkedChain(com, head)

  let txPool = TxPoolRef.new(com)

  node.addEthHandlerCapability(
    node.peerPool,
    chain,
    txPool)

  # txPool must be informed of active head
  # so it can know the latest account state
  doAssert txPool.smartHead(head, chain)

  var key: JwtSharedKey
  key.fromHex(jwtSecret).isOkOr:
    echo "JWT SECRET ERROR: ", error
    quit(QuitFailure)

  let
    hooks  = if enableAuth: @[httpJwtAuth(key)]
             else: @[]
    server = newRpcHttpServerWithParams("127.0.0.1:" & $conf.httpPort, hooks).valueOr:
      echo "Failed to create rpc server: ", error
      quit(QuitFailure)

    sync   = if com.ttd().isSome:
               BeaconSyncRef.init(node, chain, ctx.rng, conf.maxPeers, id=conf.tcpPort.int)
             else:
               BeaconSyncRef(nil)
    beaconEngine = BeaconEngineRef.new(txPool, chain)
    oracle = Oracle.new(com)
    serverApi = newServerAPI(chain)

  setupServerAPI(serverApi, server)
  setupEngineAPI(beaconEngine, server)
  # temporary disabled
  #setupDebugRpc(com, txPool, server)

  if chainFile.len > 0:
    importRlpBlocks(chainFolder / chainFile, chain, true).isOkOr:
      echo "Failed to import RLP blocks: ", error
      quit(QuitFailure)

  server.start()

  let client = newRpcHttpClient()
  waitFor client.connect("127.0.0.1", conf.httpPort, false)

  if com.ttd().isSome:
    sync.start()

  node.startListening()

  EngineEnv(
    conf   : conf,
    com    : com,
    node   : node,
    server : server,
    client : client,
    sync   : sync,
    txPool : txPool,
    chain  : chain
  )

proc close*(env: EngineEnv) =
  waitFor env.node.closeWait()
  if not env.sync.isNil:
    env.sync.stop()
  waitFor env.client.close()
  waitFor env.server.closeWait()

proc setRealTTD*(env: EngineEnv) =
  let genesis = env.com.genesisHeader
  let realTTD = genesis.difficulty
  env.com.setTTD Opt.some(realTTD)
  env.ttd = realTTD

func httpPort*(env: EngineEnv): Port =
  env.conf.httpPort

func client*(env: EngineEnv): RpcHttpClient =
  env.client

func ttd*(env: EngineEnv): UInt256 =
  env.ttd

func com*(env: EngineEnv): CommonRef =
  env.com

func node*(env: EngineEnv): ENode =
  env.node.listeningAddress

proc connect*(env: EngineEnv, node: ENode) =
  waitFor env.node.connectToNode(node)

func ID*(env: EngineEnv): string =
  $env.conf.httpPort

proc peer*(env: EngineEnv): Peer =
  doAssert(env.node.numPeers > 0)
  for peer in env.node.peers:
    return peer

proc getTxsInPool*(env: EngineEnv, txHashes: openArray[common.Hash256]): seq[Transaction] =
  result = newSeqOfCap[Transaction](txHashes.len)
  for txHash in txHashes:
    let res = env.txPool.getItem(txHash)
    if res.isErr: continue
    let item = res.get
    if item.reject == txInfoOk:
      result.add item.tx

proc numTxsInPool*(env: EngineEnv): int =
  env.txPool.numTxs

func version*(env: EngineEnv, time: EthTime): Version =
  if env.com.isCancunOrLater(time):
    Version.V3
  elif env.com.isShanghaiOrLater(time):
    Version.V2
  else:
    Version.V1

func version*(env: EngineEnv, time: Web3Quantity): Version =
  env.version(time.EthTime)

func version*(env: EngineEnv, time: uint64): Version =
  env.version(time.EthTime)

proc setBlock*(env: EngineEnv, blk: common.EthBlock): bool =
  # env.chain.setBlock(blk).isOk()
  debugEcho "TODO: fix setBlock"
  false
