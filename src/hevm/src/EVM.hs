{-# Language ImplicitParams #-}
{-# Language DataKinds #-}
{-# Language GADTs #-}
{-# Language StrictData #-}
{-# Language TemplateHaskell #-}

module EVM where

import Prelude hiding (log, exponent, GT, LT)

import Data.Text (unpack)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import EVM.ABI
import EVM.Types hiding (IllegalOverflow)
import EVM.Solidity
import EVM.Concrete (createAddress, create2Address)
import EVM.Op
import EVM.Expr (readStorage, writeStorage, readByte, readWord, writeWord, writeByte, bufLength, indexWord, litAddr, readBytes, word256At, copySlice, isLitByte)
import EVM.FeeSchedule (FeeSchedule (..))
import Options.Generic as Options
import qualified EVM.Precompiled
import qualified EVM.Expr as Expr

import Control.Lens hiding (op, (:<), (|>), (.>))
import Control.Monad.State.Strict hiding (state)

import Data.ByteString              (ByteString)
import Data.ByteString.Lazy         (fromStrict)
import Data.Map.Strict              (Map)
import Data.Set                     (Set, insert, member, fromList)
import Data.Maybe                   (fromMaybe)
import Data.Sequence                (Seq)
import Data.Vector.Storable         (Vector)
import Data.Foldable                (toList)
import Data.Word                    (Word8, Word32, Word64)
import Data.Bits                    (FiniteBits, countLeadingZeros, finiteBitSize)

import Data.Tree
import Data.Tuple.Curry
import Data.List (find)

import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as LS
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteArray       as BA
import qualified Data.Map.Strict      as Map
import qualified Data.Sequence        as Seq
import qualified Data.Tree.Zipper     as Zipper
import qualified Data.Vector          as V
import qualified Data.Vector.Storable as Vector
import qualified Data.Vector.Storable.Mutable as Vector

import qualified Data.Vector as RegularVector

import Crypto.Number.ModArithmetic (expFast)
import qualified Crypto.Hash as Crypto
import Crypto.Hash (Digest, SHA256, RIPEMD160, digestFromByteString)
import Crypto.PubKey.ECC.ECDSA (signDigestWith, PrivateKey(..), Signature(..))
import Crypto.PubKey.ECC.Types (getCurveByName, CurveName(..), Point(..))
import Crypto.PubKey.ECC.Generate (generateQ)
import Data.DoubleWord (Word256(Word256), Word128 (Word128))

-- * Data types

-- | EVM failure modes
data Error
  = BalanceTooLow W256 W256
  | UnrecognizedOpcode Word8
  | SelfDestruction
  | StackUnderrun
  | BadJumpDestination
  | Revert (Expr Buf)
  | OutOfGas Word64 Word64
  | BadCheatCode (Maybe Word32)
  | StackLimitExceeded
  | IllegalOverflow
  | Query Query
  | Choose Choose
  | StateChangeWhileStatic
  | InvalidMemoryAccess
  | CallDepthLimitReached
  | MaxCodeSizeExceeded W256 W256
  | InvalidFormat
  | PrecompileFailure
  | forall a . UnexpectedSymbolicArg Int String [Expr a]
  | DeadPath
  | NotUnique (Expr EWord)
  | SMTTimeout
  | FFI [AbiValue]
  | NonceOverflow
deriving instance Show Error

-- | The possible result states of a VM
data VMResult
  = VMFailure Error -- ^ An operation failed
  | VMSuccess (Expr Buf) -- ^ Reached STOP, RETURN, or end-of-code

deriving instance Show VMResult

-- | The state of a stepwise EVM execution
data VM = VM
  { _result         :: Maybe VMResult
  , _state          :: FrameState
  , _frames         :: [Frame]
  , _env            :: Env
  , _block          :: Block
  , _tx             :: TxState
  , _logs           :: [Expr Log]
  , _traces         :: Zipper.TreePos Zipper.Empty Trace
  , _cache          :: Cache
  , _burned         :: Word64
  , _iterations     :: Map CodeLocation Int
  , _constraints    :: [Prop]
  , _keccakEqs      :: [Prop]
  , _allowFFI       :: Bool
  }
  deriving (Show)

data Trace = Trace
  { _traceOpIx     :: Int
  , _traceContract :: Contract
  , _traceData     :: TraceData
  }
  deriving (Show)

data TraceData
  = EventTrace (Expr EWord) (Expr Buf) [Expr EWord]
  | FrameTrace FrameContext
  | QueryTrace Query
  | ErrorTrace Error
  | EntryTrace Text
  | ReturnTrace (Expr Buf) FrameContext
  deriving (Show)

-- | Queries halt execution until resolved through RPC calls or SMT queries
data Query where
  PleaseFetchContract :: Addr -> (Contract -> EVM ()) -> Query
  --PleaseMakeUnique    :: SBV a -> [SBool] -> (IsUnique a -> EVM ()) -> Query
  PleaseFetchSlot     :: Addr -> W256 -> (W256 -> EVM ()) -> Query
  PleaseAskSMT        :: Expr EWord -> [Prop] -> (BranchCondition -> EVM ()) -> Query
  PleaseDoFFI         :: [String] -> (ByteString -> EVM ()) -> Query

data Choose where
  PleaseChoosePath    :: Expr EWord -> (Bool -> EVM ()) -> Choose

instance Show Query where
  showsPrec _ = \case
    PleaseFetchContract addr _ ->
      (("<EVM.Query: fetch contract " ++ show addr ++ ">") ++)
    PleaseFetchSlot addr slot _ ->
      (("<EVM.Query: fetch slot "
        ++ show slot ++ " for "
        ++ show addr ++ ">") ++)
    PleaseAskSMT condition constraints _ ->
      (("<EVM.Query: ask SMT about "
        ++ show condition ++ " in context "
        ++ show constraints ++ ">") ++)
--     PleaseMakeUnique val constraints _ ->
--       (("<EVM.Query: make value "
--         ++ show val ++ " unique in context "
--         ++ show constraints ++ ">") ++)
    PleaseDoFFI cmd _ ->
      (("<EVM.Query: do ffi: " ++ (show cmd)) ++)

instance Show Choose where
  showsPrec _ = \case
    PleaseChoosePath _ _ ->
      (("<EVM.Choice: waiting for user to select path (0,1)") ++)

-- | Alias for the type of e.g. @exec1@.
type EVM a = State VM a

type CodeLocation = (Addr, Int)

-- | The possible return values of a SMT query
data BranchCondition = Case Bool | Unknown | Inconsistent
  deriving Show

-- | The possible return values of a `is unique` SMT query
data IsUnique a = Unique a | Multiple | InconsistentU | TimeoutU
  deriving Show

-- | The cache is data that can be persisted for efficiency:
-- any expensive query that is constant at least within a block.
data Cache = Cache
  { _fetchedContracts :: Map Addr Contract,
    _fetchedStorage :: Map W256 (Map W256 W256),
    _path :: Map (CodeLocation, Int) Bool
  } deriving Show

data StorageBase = Concrete | Symbolic
  deriving (Show, Eq)

-- | A way to specify an initial VM state
data VMOpts = VMOpts
  { vmoptContract :: Contract
  , vmoptCalldata :: (Expr Buf, [Prop])
  , vmoptStorageBase :: StorageBase
  , vmoptValue :: Expr EWord
  , vmoptPriorityFee :: W256
  , vmoptAddress :: Addr
  , vmoptCaller :: Expr EWord
  , vmoptOrigin :: Addr
  , vmoptGas :: Word64
  , vmoptGaslimit :: Word64
  , vmoptNumber :: W256
  , vmoptTimestamp :: Expr EWord
  , vmoptCoinbase :: Addr
  , vmoptPrevRandao :: W256
  , vmoptMaxCodeSize :: W256
  , vmoptBlockGaslimit :: Word64
  , vmoptGasprice :: W256
  , vmoptBaseFee :: W256
  , vmoptSchedule :: FeeSchedule Word64
  , vmoptChainId :: W256
  , vmoptCreate :: Bool
  , vmoptTxAccessList :: Map Addr [W256]
  , vmoptAllowFFI :: Bool
  } deriving Show

-- | An entry in the VM's "call/create stack"
data Frame = Frame
  { _frameContext   :: FrameContext
  , _frameState     :: FrameState
  }
  deriving (Show)

-- | Call/create info
data FrameContext
  = CreationContext
    { creationContextAddress   :: Addr
    , creationContextCodehash  :: Expr EWord
    , creationContextReversion :: Map Addr Contract
    , creationContextSubstate  :: SubState
    }
  | CallContext
    { callContextTarget    :: Addr
    , callContextContext   :: Addr
    , callContextOffset    :: W256
    , callContextSize      :: W256
    , callContextCodehash  :: Expr EWord
    , callContextAbi       :: Maybe W256
    , callContextData      :: Expr Buf
    , callContextReversion :: (Map Addr Contract, Expr Storage)
    , callContextSubState  :: SubState
    }
  deriving (Show)

-- | The "registers" of the VM along with memory and data stack
data FrameState = FrameState
  { _contract     :: Addr
  , _codeContract :: Addr
  , _code         :: ContractCode
  , _pc           :: Int
  , _stack        :: [Expr EWord]
  , _memory       :: Expr Buf
  , _memorySize   :: Word64
  , _calldata     :: Expr Buf
  , _callvalue    :: Expr EWord
  , _caller       :: Expr EWord
  , _gas          :: Word64
  , _returndata   :: Expr Buf
  , _static       :: Bool
  }
  deriving (Show)

-- | The state that spans a whole transaction
data TxState = TxState
  { _gasprice            :: W256
  , _txgaslimit          :: Word64
  , _txPriorityFee       :: W256
  , _origin              :: Addr
  , _toAddr              :: Addr
  , _value               :: Expr EWord
  , _substate            :: SubState
  , _isCreate            :: Bool
  , _txReversion         :: Map Addr Contract
  }
  deriving (Show)

-- | The "accrued substate" across a transaction
data SubState = SubState
  { _selfdestructs   :: [Addr]
  , _touchedAccounts :: [Addr]
  , _accessedAddresses :: Set Addr
  , _accessedStorageKeys :: Set (Addr, W256)
  , _refunds         :: [(Addr, Word64)]
  -- in principle we should include logs here, but do not for now
  }
  deriving (Show)

{- |
  A contract is either in creation (running its "constructor") or
  post-creation, and code in these two modes is treated differently
  by instructions like @EXTCODEHASH@, so we distinguish these two
  code types.

  The definition follows the structure of code output by solc. We need to use
  some heuristics here to deal with symbolic data regions that may be present
  in the bytecode since the fully abstract case is impractical:

  - initcode has concrete code, followed by an abstract data "section"
  - runtimecode has a fixed length, but may contain fixed size symbolic regions (due to immutable)

  hopefully we do not have to deal with dynamic immutable before we get a real data section...
-}
data ContractCode
  = InitCode ByteString (Expr Buf)     -- ^ "Constructor" code, during contract creation
  | RuntimeCode (V.Vector (Expr Byte)) -- ^ "Instance" code, after contract creation
  deriving (Show)

-- runtime err when used for symbolic code
instance Eq ContractCode where
  (InitCode a b) == (InitCode c d) = a == c && b == d
  (RuntimeCode x) == (RuntimeCode y) = x == y
  _ == _ = False

deriving instance Ord ContractCode

-- | A contract can either have concrete or symbolic storage
-- depending on what type of execution we are doing
-- data Storage
--   = Concrete (Map Word Expr EWord)
--   | Symbolic [(Expr EWord, Expr EWord)] (SArray (WordN 256) (WordN 256))
--   deriving (Show)

-- to allow for Eq Contract (which useful for debugging vmtests)
-- we mock an instance of Eq for symbolic storage.
-- It should not (cannot) be used though.
-- instance Eq Storage where
--   (==) (Concrete a) (Concrete b) = fmap forceLit a == fmap forceLit b
--   (==) (Symbolic _ _) (Concrete _) = False
--   (==) (Concrete _) (Symbolic _ _) = False
--   (==) _ _ = error "do not compare two symbolic arrays like this!"

-- | The state of a contract
data Contract = Contract
  { _contractcode :: ContractCode
  , _balance      :: W256
  , _nonce        :: W256
  , _codehash     :: Expr EWord
  , _opIxMap      :: Vector Int
  , _codeOps      :: RegularVector.Vector (Int, Op)
  , _external     :: Bool
  }

deriving instance Show Contract

-- | When doing symbolic execution, we have three different
-- ways to model the storage of contracts. This determines
-- not only the initial contract storage model but also how
-- RPC or state fetched contracts will be modeled.
data StorageModel
  = ConcreteS    -- ^ Uses `Concrete` Storage. Reading / Writing from abstract
                 -- locations causes a runtime failure. Can be nicely combined with RPC.

  | SymbolicS    -- ^ Uses `Symbolic` Storage. Reading / Writing never reaches RPC,
                 -- but always done using an SMT array with no default value.

  | InitialS     -- ^ Uses `Symbolic` Storage. Reading / Writing never reaches RPC,
                 -- but always done using an SMT array with 0 as the default value.

  deriving (Read, Show)

instance ParseField StorageModel

-- | Various environmental data
data Env = Env
  { _contracts    :: Map Addr Contract
  , _chainId      :: W256
  , _storage      :: Expr Storage
  , _origStorage  :: Map W256 (Map W256 W256)
  , _sha3Crack    :: Map W256 ByteString
  --, _keccakUsed   :: [([SWord 8], SWord 256)]
  }
  deriving (Show)


-- | Data about the block
data Block = Block
  { _coinbase    :: Addr
  , _timestamp   :: Expr EWord
  , _number      :: W256
  , _prevRandao  :: W256
  , _gaslimit    :: Word64
  , _baseFee     :: W256
  , _maxCodeSize :: W256
  , _schedule    :: FeeSchedule Word64
  } deriving Show

blankState :: FrameState
blankState = FrameState
  { _contract     = 0
  , _codeContract = 0
  , _code         = RuntimeCode mempty
  , _pc           = 0
  , _stack        = mempty
  , _memory       = mempty
  , _memorySize   = 0
  , _calldata     = mempty
  , _callvalue    = (Lit 0)
  , _caller       = (Lit 0)
  , _gas          = 0
  , _returndata   = mempty
  , _static       = False
  }

makeLenses ''FrameState
makeLenses ''Frame
makeLenses ''Block
makeLenses ''TxState
makeLenses ''SubState
makeLenses ''Contract
makeLenses ''Env
makeLenses ''Cache
makeLenses ''Trace
makeLenses ''VM

-- | An "external" view of a contract's bytecode, appropriate for
-- e.g. @EXTCODEHASH@.
bytecode :: Getter Contract (Expr Buf)
bytecode = contractcode . to f
  where f (InitCode _ _) = mempty
        f (RuntimeCode ops) = Expr.fromList ops

instance Semigroup Cache where
  a <> b = Cache
    { _fetchedContracts = Map.unionWith unifyCachedContract (view fetchedContracts a) (view fetchedContracts b)
    , _fetchedStorage = Map.unionWith unifyCachedStorage (view fetchedStorage a) (view fetchedStorage b)
    , _path = mappend (view path a) (view path b)
    }

unifyCachedStorage :: Map W256 W256 -> Map W256 W256 -> Map W256 W256
unifyCachedStorage _ _ = undefined

-- only intended for use in Cache merges, where we expect
-- everything to be Concrete
unifyCachedContract :: Contract -> Contract -> Contract
unifyCachedContract _ _ = undefined
  {-
unifyCachedContract a b = a & set storage merged
  where merged = case (view storage a, view storage b) of
                   (ConcreteStore sa, ConcreteStore sb) ->
                     ConcreteStore (mappend sa sb)
                   _ ->
                     view storage a
   -}

instance Monoid Cache where
  mempty = Cache { _fetchedContracts = mempty,
                   _fetchedStorage = mempty,
                   _path = mempty
                 }

-- * Data accessors

currentContract :: VM -> Maybe Contract
currentContract vm =
  view (env . contracts . at (view (state . codeContract) vm)) vm

-- * Data constructors

makeVm :: VMOpts -> VM
makeVm o =
  let txaccessList = vmoptTxAccessList o
      txorigin = vmoptOrigin o
      txtoAddr = vmoptAddress o
      initialAccessedAddrs = fromList $ [txorigin, txtoAddr] ++ [1..9] ++ (Map.keys txaccessList)
      initialAccessedStorageKeys = fromList $ foldMap (uncurry (map . (,))) (Map.toList txaccessList)
      touched = if vmoptCreate o then [txorigin] else [txorigin, txtoAddr]
  in
  VM
  { _result = Nothing
  , _frames = mempty
  , _tx = TxState
    { _gasprice = vmoptGasprice o
    , _txgaslimit = vmoptGaslimit o
    , _txPriorityFee = vmoptPriorityFee o
    , _origin = txorigin
    , _toAddr = txtoAddr
    , _value = vmoptValue o
    , _substate = SubState mempty touched initialAccessedAddrs initialAccessedStorageKeys mempty
    --, _accessList = txaccessList
    , _isCreate = vmoptCreate o
    , _txReversion = Map.fromList
      [(vmoptAddress o, vmoptContract o)]
    }
  , _logs = []
  , _traces = Zipper.fromForest []
  , _block = Block
    { _coinbase = vmoptCoinbase o
    , _timestamp = vmoptTimestamp o
    , _number = vmoptNumber o
    , _prevRandao = vmoptPrevRandao o
    , _maxCodeSize = vmoptMaxCodeSize o
    , _gaslimit = vmoptBlockGaslimit o
    , _baseFee = vmoptBaseFee o
    , _schedule = vmoptSchedule o
    }
  , _state = FrameState
    { _pc = 0
    , _stack = mempty
    , _memory = mempty
    , _memorySize = 0
    , _code = view contractcode $ vmoptContract o
    , _contract = vmoptAddress o
    , _codeContract = vmoptAddress o
    , _calldata = fst $ vmoptCalldata o
    , _callvalue = vmoptValue o
    , _caller = vmoptCaller o
    , _gas = vmoptGas o
    , _returndata = mempty
    , _static = False
    }
  , _env = Env
    { _sha3Crack = mempty
    , _chainId = vmoptChainId o
    , _storage = if vmoptStorageBase o == Concrete then EmptyStore else AbstractStore
    , _origStorage = mempty
    , _contracts = Map.fromList
      [(vmoptAddress o, vmoptContract o)]
    --, _keccakUsed = mempty
    --, _storageModel = vmoptStorageModel o
    }
  , _cache = Cache mempty mempty mempty
  , _burned = 0
  , _constraints = snd $ vmoptCalldata o
  , _keccakEqs = mempty
  , _iterations = mempty
  , _allowFFI = vmoptAllowFFI o
  }

-- | Initialize empty contract with given code
initialContract :: ContractCode -> Contract
initialContract theContractCode = Contract
  { _contractcode = theContractCode
  , _codehash = hashcode theContractCode
  , _balance  = 0
  , _nonce    = if creation then 1 else 0
  , _opIxMap  = mkOpIxMap theContractCode
  , _codeOps  = mkCodeOps theContractCode
  , _external = False
  } where
      creation = case theContractCode of
        InitCode _ _  -> True
        RuntimeCode _ -> False

-- * Opcode dispatch (exec1)

-- | Update program counter
next :: (?op :: Word8) => EVM ()
next = modifying (state . pc) (+ (opSize ?op))

-- | Executes the EVM one step
exec1 :: EVM ()
exec1 = do
  vm <- get

  let
    -- Convenience function to access parts of the current VM state.
    -- Arcane type signature needed to avoid monomorphism restriction.
    the :: (b -> VM -> Const a VM) -> ((a -> Const a a) -> b) -> a
    the f g = view (f . g) vm

    -- Convenient aliases
    mem  = the state memory
    stk  = the state stack
    self = the state contract
    this = fromMaybe (error "internal error: state contract") (preview (ix self) (the env contracts))

    fees@FeeSchedule {..} = the block schedule

    doStop = finishFrame (FrameReturned mempty)

  if self > 0x0 && self <= 0x9 then do
    -- call to precompile
    let ?op = 0x00 -- dummy value
    case bufLength (the state calldata) of
      (Lit calldatasize) -> do
          copyBytesToMemory (the state calldata) (Lit calldatasize) (Lit 0) (Lit 0)
          executePrecompile self (the state gas) 0 calldatasize 0 0 []
          vmx <- get
          case view (state.stack) vmx of
            (x:_) -> case x of
              Lit (num -> x' :: Integer) -> case x' of
                0 -> do
                  fetchAccount self $ \_ -> do
                    touchAccount self
                    vmError PrecompileFailure
                _ -> fetchAccount self $ \_ -> do
                    touchAccount self
                    out <- use (state . returndata)
                    finishFrame (FrameReturned out)
              e -> vmError $
                UnexpectedSymbolicArg (view (state . pc) vmx) "precompile returned a symbolic value" [e]
            _ ->
              underrun
      e -> vmError $ UnexpectedSymbolicArg (the state pc) "cannot call precompiles with symbolic data" [e]

  else if the state pc >= opslen (the state code)
    then doStop

    else do
      let ?op = case (the state code) of
                  InitCode conc _ -> BS.index conc (the state pc)
                  RuntimeCode ops ->
                    fromMaybe (error "could not analyze symbolic code") $
                      unlitByte $ ops V.! the state pc

      case ?op of

        -- op: PUSH
        x | x >= 0x60 && x <= 0x7f -> do
          let !n = num x - 0x60 + 1
              !xs = case the state code of
                InitCode conc _ -> Lit $ word $ padRight n $ BS.take n (BS.drop (1 + the state pc) conc)
                RuntimeCode ops ->
                  let bytes = V.take n $ V.drop (1 + the state pc) ops
                  in if all isLitByte bytes then -- optimize concrete path
                       let litBytes = V.toList $ V.catMaybes $ unlitByte <$> bytes
                           padded = BS.replicate (32 - length litBytes) 0 <> BS.pack litBytes
                       in Lit $ word padded
                     else readWord (Lit 0) $ Expr.fromList $ padLeft' 32 bytes
          limitStack 1 $
            burn g_verylow $ do
              next
              pushSym xs

        -- op: DUP
        x | x >= 0x80 && x <= 0x8f -> do
          let !i = x - 0x80 + 1
          case preview (ix (num i - 1)) stk of
            Nothing -> underrun
            Just y ->
              limitStack 1 $
                burn g_verylow $ do
                  next
                  pushSym y

        -- op: SWAP
        x | x >= 0x90 && x <= 0x9f -> do
          let i = num (x - 0x90 + 1)
          if length stk < i + 1
            then underrun
            else
              burn g_verylow $ do
                next
                zoom (state . stack) $ do
                  assign (ix 0) (stk ^?! ix i)
                  assign (ix i) (stk ^?! ix 0)

        -- op: LOG
        x | x >= 0xa0 && x <= 0xa4 ->
          notStatic $
          let n = (num x - 0xa0) in
          case stk of
            (xOffset':xSize':xs) ->
              if length xs < n
              then underrun
              else
                forceConcrete2 (xOffset', xSize') "LOG" $ \(xOffset, xSize) -> do
                    let (topics, xs') = splitAt n xs
                        bytes         = readMemory xOffset' xSize' vm
                        logs'         = (LogEntry (litAddr self) bytes topics) : (view logs vm)
                    burn (g_log + g_logdata * (num xSize) + num n * g_logtopic) $
                      accessMemoryRange fees xOffset xSize $ do
                        traceTopLog logs'
                        next
                        assign (state . stack) xs'
                        assign logs logs'
            _ ->
              underrun

        -- op: STOP
        0x00 -> doStop

        -- op: ADD
        0x01 -> stackOp2 (const g_verylow) (uncurry Expr.add)
        -- op: MUL
        0x02 -> stackOp2 (const g_low) (uncurry Expr.mul)
        -- op: SUB
        0x03 -> stackOp2 (const g_verylow) (uncurry Expr.sub)

        -- op: DIV
        0x04 -> stackOp2 (const g_low) (uncurry Expr.div)

        -- op: SDIV
        0x05 -> stackOp2 (const g_low) (uncurry Expr.sdiv)

        -- op: MOD
        0x06 -> stackOp2 (const g_low) (uncurry Expr.mod)

        -- op: SMOD
        0x07 -> stackOp2 (const g_low) (uncurry Expr.smod)
        -- op: ADDMOD
        0x08 -> stackOp3 (const g_mid) (uncurryN Expr.addmod)
        -- op: MULMOD
        0x09 -> stackOp3 (const g_mid) (uncurryN Expr.mulmod)

        -- op: LT
        0x10 -> stackOp2 (const g_verylow) (uncurry Expr.lt)
        -- op: GT
        0x11 -> stackOp2 (const g_verylow) (uncurry Expr.gt)
        -- op: SLT
        0x12 -> stackOp2 (const g_verylow) (uncurry Expr.slt)
        -- op: SGT
        0x13 -> stackOp2 (const g_verylow) (uncurry Expr.sgt)

        -- op: EQ
        0x14 -> stackOp2 (const g_verylow) (uncurry Expr.eq)
        -- op: ISZERO
        0x15 -> stackOp1 (const g_verylow) Expr.iszero

        -- op: AND
        0x16 -> stackOp2 (const g_verylow) (uncurry Expr.and)
        -- op: OR
        0x17 -> stackOp2 (const g_verylow) (uncurry Expr.or)
        -- op: XOR
        0x18 -> stackOp2 (const g_verylow) (uncurry Expr.xor)
        -- op: NOT
        0x19 -> stackOp1 (const g_verylow) Expr.not

        -- op: BYTE
        0x1a -> stackOp2 (const g_verylow) (\(i, w) -> Expr.padByte $ Expr.indexWord i w)

        -- op: SHL
        0x1b -> stackOp2 (const g_verylow) (uncurry Expr.shl)
        -- op: SHR
        0x1c -> stackOp2 (const g_verylow) (uncurry Expr.shr)
        -- op: SAR
        0x1d -> stackOp2 (const g_verylow) (uncurry Expr.sar)

        -- op: SHA3
        -- more accurately refered to as KECCAK
        0x20 ->
          case stk of
            (xOffset' : xSize' : xs) ->
              forceConcrete xOffset' "sha3 offset must be concrete" $
                \xOffset -> forceConcrete xSize' "sha3 size must be concrete" $ \xSize ->
                  burn (g_sha3 + g_sha3word * ceilDiv (num xSize) 32) $
                    accessMemoryRange fees xOffset xSize $ do
                      (hash, invMap) <- case readMemory xOffset' xSize' vm of
                                          ConcreteBuf bs -> do
                                            let hash' = keccak' bs
                                            eqs <- use keccakEqs
                                            assign keccakEqs $ PEq (Lit hash') (Keccak (ConcreteBuf bs)):eqs
                                            pure (Lit hash', Map.singleton hash' bs)
                                          buf -> pure (Keccak buf, mempty)
                      next
                      assign (state . stack) (hash : xs)
                      (env . sha3Crack) <>= invMap
            _ -> underrun

        -- op: ADDRESS
        0x30 ->
          limitStack 1 $
            burn g_base (next >> push (num self))

        -- op: BALANCE
        0x31 ->
          case stk of
            (x':xs) -> forceConcrete x' "BALANCE" $ \x ->
              accessAndBurn (num x) $
                fetchAccount (num x) $ \c -> do
                  next
                  assign (state . stack) xs
                  push (num $ view balance c)
            [] ->
              underrun

        -- op: ORIGIN
        0x32 ->
          limitStack 1 . burn g_base $
            next >> push (num (the tx origin))

        -- op: CALLER
        0x33 ->
          limitStack 1 . burn g_base $
            next >> pushSym (the state caller)

        -- op: CALLVALUE
        0x34 ->
          limitStack 1 . burn g_base $
            next >> pushSym (the state callvalue)

        -- op: CALLDATALOAD
        0x35 -> stackOp1 (const g_verylow) $
          \ind -> Expr.readWord ind (the state calldata)

        -- op: CALLDATASIZE
        0x36 ->
          limitStack 1 . burn g_base $
            next >> pushSym (bufLength (the state calldata))

        -- op: CALLDATACOPY
        0x37 ->
          case stk of
            (xTo' : xFrom : xSize' : xs) ->
              forceConcrete2 (xTo', xSize') "CALLDATACOPY" $
                \(xTo, xSize) ->
                  burn (g_verylow + g_copy * ceilDiv (num xSize) 32) $
                    accessMemoryRange fees xTo xSize $ do
                      next
                      assign (state . stack) xs
                      copyBytesToMemory (the state calldata) xSize' xFrom xTo'
            _ -> underrun

        -- op: CODESIZE
        0x38 ->
          limitStack 1 . burn g_base $
            next >> pushSym (codelen (the state code))

        -- op: CODECOPY
        0x39 ->
          case stk of
            (memOffset' : codeOffset : n' : xs) ->
              forceConcrete2 (memOffset', n') "CODECOPY" $
                \(memOffset,n) -> do
                  case toWord64 n of
                    Nothing -> vmError IllegalOverflow
                    Just n'' ->
                      if n'' <= ( (maxBound :: Word64) - g_verylow ) `div` g_copy * 32 then
                        burn (g_verylow + g_copy * ceilDiv (num n) 32) $
                          accessMemoryRange fees memOffset n $ do
                            next
                            assign (state . stack) xs
                            copyBytesToMemory (toBuf $ the state code) n' codeOffset memOffset'
                      else vmError IllegalOverflow
            _ -> underrun

        -- op: GASPRICE
        0x3a ->
          limitStack 1 . burn g_base $
            next >> push (the tx gasprice)

        -- op: EXTCODESIZE
        0x3b ->
          case stk of
            (x':xs) -> case x' of
              (Lit x) -> if x == num cheatCode
                then do
                  next
                  assign (state . stack) xs
                  pushSym (Lit 1)
                else
                  accessAndBurn (num x) $
                    fetchAccount (num x) $ \c -> do
                      next
                      assign (state . stack) xs
                      pushSym (bufLength (view bytecode c))
              _ -> do
                assign (state . stack) xs
                pushSym (CodeSize x')
            [] ->
              underrun

        -- op: EXTCODECOPY
        0x3c ->
          case stk of
            ( extAccount'
              : memOffset'
              : codeOffset
              : codeSize'
              : xs ) ->
              forceConcrete3 (extAccount', memOffset', codeSize') "EXTCODECOPY" $
                \(extAccount, memOffset, codeSize) -> do
                  acc <- accessAccountForGas (num extAccount)
                  let cost = if acc then g_warm_storage_read else g_cold_account_access
                  burn (cost + g_copy * ceilDiv (num codeSize) 32) $
                    accessMemoryRange fees memOffset codeSize $
                      fetchAccount (num extAccount) $ \c -> do
                        next
                        assign (state . stack) xs
                        copyBytesToMemory (view bytecode c) codeSize' codeOffset memOffset'
            _ -> underrun

        -- op: RETURNDATASIZE
        0x3d ->
          limitStack 1 . burn g_base $
            next >> pushSym (bufLength (the state returndata))

        -- op: RETURNDATACOPY
        0x3e ->
          case stk of
            (xTo' : xFrom : xSize' :xs) -> forceConcrete2 (xTo', xSize') "RETURNDATACOPY" $
              \(xTo, xSize) ->
                burn (g_verylow + g_copy * ceilDiv (num xSize) 32) $
                  accessMemoryRange fees xTo xSize $ do
                    next
                    assign (state . stack) xs

                    let jump True = vmError EVM.InvalidMemoryAccess
                        jump False = copyBytesToMemory (the state returndata) xSize' xFrom xTo'

                    case (xFrom, bufLength (the state returndata)) of
                      (Lit f, Lit l) ->
                        jump $ l < f + xSize || f + xSize < f
                      _ -> do
                        let oob = Expr.lt (bufLength $ the state returndata) (Expr.add xFrom xSize')
                            overflow = Expr.lt (Expr.add xFrom xSize') (xFrom)
                        loc <- codeloc
                        branch loc (Expr.or oob overflow) jump
            _ -> underrun

        -- op: EXTCODEHASH
        0x3f ->
          case stk of
            (x':xs) -> forceConcrete x' "EXTCODEHASH" $ \x ->
              accessAndBurn (num x) $ do
                next
                assign (state . stack) xs
                fetchAccount (num x) $ \c ->
                   if accountEmpty c
                     then push (num (0 :: Int))
                     else pushSym $ keccak (view bytecode c)
            [] ->
              underrun

        -- op: BLOCKHASH
        0x40 -> do
          -- We adopt the fake block hash scheme of the VMTests,
          -- so that blockhash(i) is the hash of i as decimal ASCII.
          stackOp1 (const g_blockhash) $ \case
            (Lit i) -> if i + 256 < the block number || i >= the block number
                       then Lit 0
                       else (num i :: Integer) & show & Char8.pack & keccak' & Lit
            i -> BlockHash i

        -- op: COINBASE
        0x41 ->
          limitStack 1 . burn g_base $
            next >> push (num (the block coinbase))

        -- op: TIMESTAMP
        0x42 ->
          limitStack 1 . burn g_base $
            next >> pushSym (the block timestamp)

        -- op: NUMBER
        0x43 ->
          limitStack 1 . burn g_base $
            next >> push (the block number)

        -- op: PREVRANDAO
        0x44 -> do
          limitStack 1 . burn g_base $
            next >> push (the block prevRandao)

        -- op: GASLIMIT
        0x45 ->
          limitStack 1 . burn g_base $
            next >> push (num $ the block gaslimit)

        -- op: CHAINID
        0x46 ->
          limitStack 1 . burn g_base $
            next >> push (the env chainId)

        -- op: SELFBALANCE
        0x47 ->
          limitStack 1 . burn g_low $
            next >> push (view balance this)

        -- op: BASEFEE
        0x48 ->
          limitStack 1 . burn g_base $
            next >> push (the block baseFee)

        -- op: POP
        0x50 ->
          case stk of
            (_:xs) -> burn g_base (next >> assign (state . stack) xs)
            _      -> underrun

        -- op: MLOAD
        0x51 ->
          case stk of
            (x':xs) -> forceConcrete x' "MLOAD" $ \x ->
              burn g_verylow $
                accessMemoryWord fees x $ do
                  next
                  assign (state . stack) (readWord (Lit x) mem : xs)
            _ -> underrun

        -- op: MSTORE
        0x52 ->
          case stk of
            (x':y:xs) -> forceConcrete x' "MSTORE index" $ \x ->
              burn g_verylow $
                accessMemoryWord fees x $ do
                  next
                  assign (state . memory) (writeWord (Lit x) y mem)
                  assign (state . stack) xs
            _ -> underrun

        -- op: MSTORE8
        0x53 ->
          case stk of
            (x':y:xs) -> forceConcrete x' "MSTORE8" $ \x ->
              burn g_verylow $
                accessMemoryRange fees x 1 $ do
                  let yByte = indexWord (Lit 31) y
                  next
                  modifying (state . memory) (writeByte (Lit x) yByte)
                  assign (state . stack) xs
            _ -> underrun

        -- op: SLOAD
        0x54 ->
          case stk of
            (x:xs) -> do
              acc <- accessStorageForGas self x
              let cost = if acc then g_warm_storage_read else g_cold_sload
              burn cost $
                accessStorage self x $ \y -> do
                  next
                  assign (state . stack) (y:xs)
            _ -> underrun

        -- op: SSTORE
        0x55 ->
          notStatic $
          case stk of
            (x:new:xs) ->
              accessStorage self x $ \current -> do
                availableGas <- use (state . gas)

                if num availableGas <= g_callstipend
                  then finishFrame (FrameErrored (OutOfGas availableGas (num g_callstipend)))
                  else do
                    let original = case readStorage (litAddr self) x (ConcreteStore $ the env origStorage) of
                                     Just (Lit v) -> v
                                     _ -> 0
                    let storage_cost = case (maybeLitWord current, maybeLitWord new) of
                                 (Just current', Just new') ->
                                    if (current' == new') then g_sload
                                    else if (current' == original) && (original == 0) then g_sset
                                    else if (current' == original) then g_sreset
                                    else g_sload

                                 -- if any of the arguments are symbolic,
                                 -- assume worst case scenario
                                 _ -> g_sset

                    acc <- accessStorageForGas self x
                    let cold_storage_cost = if acc then 0 else g_cold_sload
                    burn (storage_cost + cold_storage_cost) $ do
                      next
                      assign (state . stack) xs
                      modifying (env . storage)
                        (writeStorage (litAddr self) x new)

                      case (maybeLitWord current, maybeLitWord new) of
                         (Just current', Just new') ->
                            unless (current' == new') $
                              if current' == original
                              then when (original /= 0 && new' == 0) $
                                      refund (g_sreset + g_access_list_storage_key)
                              else do
                                      when (original /= 0) $
                                        if new' == 0
                                        then refund (g_sreset + g_access_list_storage_key)
                                        else unRefund (g_sreset + g_access_list_storage_key)
                                      when (original == new') $
                                        if original == 0
                                        then refund (g_sset - g_sload)
                                        else refund (g_sreset - g_sload)
                         -- if any of the arguments are symbolic,
                         -- don't change the refund counter
                         _ -> noop
            _ -> underrun

        -- op: JUMP
        0x56 ->
          case stk of
            (x:xs) ->
              burn g_mid $ forceConcrete x "JUMP: symbolic jumpdest" $ \x' ->
                checkJump x' xs
            _ -> underrun

        -- op: JUMPI
        0x57 -> do
          case stk of
            (x:y:xs) -> forceConcrete x "JUMPI: symbolic jumpdest" $ \x' ->
                burn g_high $
                  let jump :: Bool -> EVM ()
                      jump False = assign (state . stack) xs >> next
                      jump _    = checkJump x' xs
                  in case maybeLitWord y of
                      Just y' -> jump (0 /= y')
                      -- if the jump condition is symbolic, we explore both sides
                      Nothing -> do
                        loc <- codeloc
                        branch loc y jump
            _ -> underrun

        -- op: PC
        0x58 ->
          limitStack 1 . burn g_base $
            next >> push (num (the state pc))

        -- op: MSIZE
        0x59 ->
          limitStack 1 . burn g_base $
            next >> push (num (the state memorySize))

        -- op: GAS
        0x5a ->
          limitStack 1 . burn g_base $
            next >> push (num (the state gas - g_base))

        -- op: JUMPDEST
        0x5b -> burn g_jumpdest next

        -- op: EXP
        0x0a ->
          -- NOTE: this can be done symbolically using unrolling like this:
          --       https://hackage.haskell.org/package/sbv-9.0/docs/src/Data.SBV.Core.Model.html#.%5E
          --       However, it requires symbolic gas, since the gas depends on the exponent
          case stk of
            (base:exponent':xs) -> forceConcrete exponent' "EXP: symbolic exponent" $ \exponent ->
              let cost = if exponent == 0
                         then g_exp
                         else g_exp + g_expbyte * num (ceilDiv (1 + log2 exponent) 8)
              in burn cost $ do
                next
                state . stack .= Expr.exp base exponent' : xs
            _ -> underrun

        -- op: SIGNEXTEND
        0x0b -> stackOp2 (const g_low) (uncurry Expr.sex)

        -- op: CREATE
        0xf0 ->
          notStatic $
          case stk of
            (xValue' : xOffset' : xSize' : xs) -> forceConcrete3 (xValue', xOffset', xSize') "CREATE" $
              \(xValue, xOffset, xSize) -> do
                accessMemoryRange fees xOffset xSize $ do
                  availableGas <- use (state . gas)
                  let
                    newAddr = createAddress self (view nonce this)
                    (cost, gas') = costOfCreate fees availableGas 0
                  _ <- accessAccountForGas newAddr
                  burn (cost - gas') $ do
                    -- unfortunately we have to apply some (pretty hacky)
                    -- heuristics here to parse the unstructured buffer read
                    -- from memory into a code and data section
                    let initCode = readMemory xOffset' xSize' vm
                    create self this (num gas') xValue xs newAddr initCode
            _ -> underrun

        -- op: CALL
        0xf1 ->
          case stk of
            ( xGas'
              : xTo
              : xValue'
              : xInOffset'
              : xInSize'
              : xOutOffset'
              : xOutSize'
              : xs
             ) -> forceConcrete6 (xGas', xValue', xInOffset', xInSize', xOutOffset', xOutSize') "CALL" $
              \(xGas, xValue, xInOffset, xInSize, xOutOffset, xOutSize) ->
                (if xValue > 0 then notStatic else id) $
                  delegateCall this (num xGas) xTo xTo xValue xInOffset xInSize xOutOffset xOutSize xs $ \callee -> do
                    zoom state $ do
                      assign callvalue (Lit xValue)
                      assign caller (litAddr self)
                      assign contract callee
                    transfer self callee xValue
                    touchAccount self
                    touchAccount callee
            _ ->
              underrun

        -- op: CALLCODE
        0xf2 ->
          case stk of
            ( xGas'
              : xTo
              : xValue'
              : xInOffset'
              : xInSize'
              : xOutOffset'
              : xOutSize'
              : xs
              ) -> forceConcrete6 (xGas', xValue', xInOffset', xInSize', xOutOffset', xOutSize') "CALLCODE" $
                \(xGas, xValue, xInOffset, xInSize, xOutOffset, xOutSize) ->
                  delegateCall this (num xGas) xTo (litAddr self) xValue xInOffset xInSize xOutOffset xOutSize xs $ \_ -> do
                    zoom state $ do
                      assign callvalue (Lit xValue)
                      assign caller (litAddr self)
                    touchAccount self
            _ ->
              underrun

        -- op: RETURN
        0xf3 ->
          case stk of
            (xOffset' : xSize' :_) -> forceConcrete2 (xOffset', xSize') "RETURN" $ \(xOffset, xSize) ->
              accessMemoryRange fees xOffset xSize $ do
                let
                  output = readMemory xOffset' xSize' vm
                  codesize = fromMaybe (error "RETURN: cannot return dynamically sized abstract data")
                               . unlit . bufLength $ output
                  maxsize = the block maxCodeSize
                  creation = case view frames vm of
                    [] -> the tx isCreate
                    frame:_ -> case view frameContext frame of
                       CreationContext {} -> True
                       CallContext {} -> False
                if creation
                then
                  if codesize > maxsize
                  then
                    finishFrame (FrameErrored (MaxCodeSizeExceeded maxsize codesize))
                  else do
                    let frameReturned = burn (g_codedeposit * num codesize) $
                                          finishFrame (FrameReturned output)
                        frameErrored = finishFrame $ FrameErrored InvalidFormat
                    case readByte (Lit 0) output of
                      LitByte 0xef -> frameErrored
                      LitByte _ -> frameReturned
                      y -> do
                        loc <- codeloc
                        branch loc (Expr.eqByte y (LitByte 0xef)) $ \case
                          True -> frameErrored
                          False -> frameReturned
                else
                   finishFrame (FrameReturned output)
            _ -> underrun

        -- op: DELEGATECALL
        0xf4 ->
          case stk of
            (xGas'
             :xTo
             :xInOffset'
             :xInSize'
             :xOutOffset'
             :xOutSize'
             :xs) -> forceConcrete5 (xGas', xInOffset', xInSize', xOutOffset', xOutSize') "DELEGATECALL" $
              \(xGas, xInOffset, xInSize, xOutOffset, xOutSize) ->
                delegateCall this (num xGas) xTo (litAddr self) 0 xInOffset xInSize xOutOffset xOutSize xs $ \_ -> do
                  touchAccount self
            _ -> underrun

        -- op: CREATE2
        0xf5 -> notStatic $
          case stk of
            (xValue'
             :xOffset'
             :xSize'
             :xSalt'
             :xs) -> forceConcrete4 (xValue', xOffset', xSize', xSalt') "CREATE2" $
              \(xValue, xOffset, xSize, xSalt) ->
                accessMemoryRange fees xOffset xSize $ do
                  availableGas <- use (state . gas)

                  forceConcreteBuf (readMemory xOffset' xSize' vm) "CREATE2" $
                    \initCode -> do
                      let
                        newAddr  = create2Address self xSalt initCode
                        (cost, gas') = costOfCreate fees availableGas xSize
                      _ <- accessAccountForGas newAddr
                      burn (cost - gas') $ create self this gas' xValue xs newAddr (ConcreteBuf initCode)
            _ -> underrun

        -- op: STATICCALL
        0xfa ->
          case stk of
            (xGas'
             :xTo
             :xInOffset'
             :xInSize'
             :xOutOffset'
             :xOutSize'
             :xs) -> forceConcrete5 (xGas', xInOffset', xInSize', xOutOffset', xOutSize') "STATICCALL" $
              \(xGas, xInOffset, xInSize, xOutOffset, xOutSize) -> do
                delegateCall this (num xGas) xTo xTo 0 xInOffset xInSize xOutOffset xOutSize xs $ \callee -> do
                  zoom state $ do
                    assign callvalue (Lit 0)
                    assign caller (litAddr self)
                    assign contract callee
                    assign static True
                  touchAccount self
                  touchAccount callee
            _ ->
              underrun

        -- op: SELFDESTRUCT
        0xff ->
          notStatic $
          case stk of
            [] -> underrun
            (xTo':_) -> forceConcrete xTo' "SELFDESTRUCT" $ \(num -> xTo) -> do
              acc <- accessAccountForGas (num xTo)
              let cost = if acc then 0 else g_cold_account_access
                  funds = view balance this
                  recipientExists = accountExists xTo vm
                  c_new = if not recipientExists && funds /= 0
                          then g_selfdestruct_newaccount
                          else 0
              burn (g_selfdestruct + c_new + cost) $ do
                   selfdestruct self
                   touchAccount xTo

                   if funds /= 0
                   then fetchAccount xTo $ \_ -> do
                          env . contracts . ix xTo . balance += funds
                          assign (env . contracts . ix self . balance) 0
                          doStop
                   else doStop

        -- op: REVERT
        0xfd ->
          case stk of
            (xOffset':xSize':_) -> forceConcrete2 (xOffset', xSize') "REVERT" $ \(xOffset, xSize) ->
              accessMemoryRange fees xOffset xSize $ do
                let output = readMemory xOffset' xSize' vm
                finishFrame (FrameReverted output)
            _ -> underrun

        xxx ->
          vmError (UnrecognizedOpcode xxx)

transfer :: Addr -> Addr -> W256 -> EVM ()
transfer xFrom xTo xValue =
  zoom (env . contracts) $ do
    ix xFrom . balance -= xValue
    ix xTo  . balance += xValue

-- | Checks a *CALL for failure; OOG, too many callframes, memory access etc.
callChecks
  :: (?op :: Word8)
  => Contract -> Word64 -> Addr -> Addr -> W256 -> W256 -> W256 -> W256 -> W256 -> [Expr EWord]
   -- continuation with gas available for call
  -> (Word64 -> EVM ())
  -> EVM ()
callChecks this xGas xContext xTo xValue xInOffset xInSize xOutOffset xOutSize xs continue = do
  vm <- get
  let fees = view (block . schedule) vm
  accessMemoryRange fees xInOffset xInSize $
    accessMemoryRange fees xOutOffset xOutSize $ do
      availableGas <- use (state . gas)
      let recipientExists = accountExists xContext vm
      (cost, gas') <- costOfCall fees recipientExists xValue availableGas xGas xTo
      burn (cost - gas') $ do
        if xValue > num (view balance this)
        then do
          assign (state . stack) (Lit 0 : xs)
          assign (state . returndata) mempty
          pushTrace $ ErrorTrace $ BalanceTooLow xValue (view balance this)
          next
        else if length (view frames vm) >= 1024
             then do
               assign (state . stack) (Lit 0 : xs)
               assign (state . returndata) mempty
               pushTrace $ ErrorTrace CallDepthLimitReached
               next
             else continue gas'

precompiledContract
  :: (?op :: Word8)
  => Contract
  -> Word64
  -> Addr
  -> Addr
  -> W256
  -> W256 -> W256 -> W256 -> W256
  -> [Expr EWord]
  -> EVM ()
precompiledContract this xGas precompileAddr recipient xValue inOffset inSize outOffset outSize xs =
  callChecks this xGas recipient precompileAddr xValue inOffset inSize outOffset outSize xs $ \gas' ->
  do
    executePrecompile precompileAddr gas' inOffset inSize outOffset outSize xs
    self <- use (state . contract)
    stk <- use (state . stack)
    pc' <- use (state . pc)
    case stk of
      (x:_) -> case maybeLitWord x of
        Just 0 ->
          return ()
        Just 1 ->
          fetchAccount recipient $ \_ -> do

          transfer self recipient xValue
          touchAccount self
          touchAccount recipient
        _ -> vmError $ UnexpectedSymbolicArg pc' "symbolic return value from precompile" [x]
      _ -> underrun

executePrecompile
  :: (?op :: Word8)
  => Addr
  -> Word64 -> W256 -> W256 -> W256 -> W256 -> [Expr EWord]
  -> EVM ()
executePrecompile preCompileAddr gasCap inOffset inSize outOffset outSize xs  = do
  vm <- get
  let input = readMemory (Lit inOffset) (Lit inSize) vm
      fees = view (block . schedule) vm
      cost = costOfPrecompile fees preCompileAddr input
      notImplemented = error $ "precompile at address " <> show preCompileAddr <> " not yet implemented"
      precompileFail = burn (gasCap - cost) $ do
                         assign (state . stack) (Lit 0 : xs)
                         pushTrace $ ErrorTrace PrecompileFailure
                         next
  if cost > gasCap then
    burn gasCap $ do
      assign (state . stack) (Lit 0 : xs)
      next
  else
    burn cost $
      case preCompileAddr of
        -- ECRECOVER
        0x1 ->
         -- TODO: support symbolic variant
         forceConcreteBuf input "ECRECOVER" $ \input' ->
          case EVM.Precompiled.execute 0x1 (truncpadlit 128 input') 32 of
            Nothing -> do
              -- return no output for invalid signature
              assign (state . stack) (Lit 1 : xs)
              assign (state . returndata) mempty
              next
            Just output -> do
              assign (state . stack) (Lit 1 : xs)
              assign (state . returndata) (ConcreteBuf output)
              copyBytesToMemory (ConcreteBuf output) (Lit outSize) (Lit 0) (Lit outOffset)
              next

        -- SHA2-256
        0x2 ->
          let
            hash = case input of
                     ConcreteBuf input' -> sha256Buf input'
                     _ -> WriteWord (Lit 0) (SHA256 input) mempty
            sha256Buf x = ConcreteBuf $ BA.convert (Crypto.hash x :: Digest SHA256)
          in do
            assign (state . stack) (Lit 1 : xs)
            assign (state . returndata) hash
            copyBytesToMemory hash (Lit outSize) (Lit 0) (Lit outOffset)
            next

        -- RIPEMD-160
        0x3 ->
         -- TODO: support symbolic variant
         forceConcreteBuf input "RIPEMD160" $ \input' ->

          let
            padding = BS.pack $ replicate 12 0
            hash' = BA.convert (Crypto.hash input' :: Digest RIPEMD160)
            hash  = ConcreteBuf $ padding <> hash'
          in do
            assign (state . stack) (Lit 1 : xs)
            assign (state . returndata) hash
            copyBytesToMemory hash (Lit outSize) (Lit 0) (Lit outOffset)
            next

        -- IDENTITY
        0x4 -> do
            assign (state . stack) (Lit 1 : xs)
            assign (state . returndata) input
            copyCallBytesToMemory input (Lit outSize) (Lit 0) (Lit outOffset)
            next

        -- MODEXP
        0x5 ->
         -- TODO: support symbolic variant
         forceConcreteBuf input "MODEXP" $ \input' ->

          let
            (lenb, lene, lenm) = parseModexpLength input'

            output = ConcreteBuf $
              if isZero (96 + lenb + lene) lenm input'
              then truncpadlit (num lenm) (asBE (0 :: Int))
              else
                let
                  b = asInteger $ lazySlice 96 lenb input'
                  e = asInteger $ lazySlice (96 + lenb) lene input'
                  m = asInteger $ lazySlice (96 + lenb + lene) lenm input'
                in
                  padLeft (num lenm) (asBE (expFast b e m))
          in do
            assign (state . stack) (Lit 1 : xs)
            assign (state . returndata) output
            copyBytesToMemory output (Lit outSize) (Lit 0) (Lit outOffset)
            next

        -- ECADD
        0x6 ->
         -- TODO: support symbolic variant
         forceConcreteBuf input "ECADD" $ \input' ->
           case EVM.Precompiled.execute 0x6 (truncpadlit 128 input') 64 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = ConcreteBuf $ truncpadlit 64 output
            assign (state . stack) (Lit 1 : xs)
            assign (state . returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
            next

        -- ECMUL
        0x7 ->
         -- TODO: support symbolic variant
         forceConcreteBuf input "ECMUL" $ \input' ->

          case EVM.Precompiled.execute 0x7 (truncpadlit 96 input') 64 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = ConcreteBuf $ truncpadlit 64 output
            assign (state . stack) (Lit 1 : xs)
            assign (state . returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
            next

        -- ECPAIRING
        0x8 ->
         -- TODO: support symbolic variant
         forceConcreteBuf input "ECPAIR" $ \input' ->

          case EVM.Precompiled.execute 0x8 input' 32 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = ConcreteBuf $ truncpadlit 32 output
            assign (state . stack) (Lit 1 : xs)
            assign (state . returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
            next

        -- BLAKE2
        0x9 ->
         -- TODO: support symbolic variant
         forceConcreteBuf input "BLAKE2" $ \input' -> do

          case (BS.length input', 1 >= BS.last input') of
            (213, True) -> case EVM.Precompiled.execute 0x9 input' 64 of
              Just output -> do
                let truncpaddedOutput = ConcreteBuf $ truncpadlit 64 output
                assign (state . stack) (Lit 1 : xs)
                assign (state . returndata) truncpaddedOutput
                copyBytesToMemory truncpaddedOutput (Lit outSize) (Lit 0) (Lit outOffset)
                next
              Nothing -> precompileFail
            _ -> precompileFail


        _   -> notImplemented

truncpadlit :: Int -> ByteString -> ByteString
truncpadlit n xs = if m > n then BS.take n xs
                   else BS.append xs (BS.replicate (n - m) 0)
  where m = BS.length xs

lazySlice :: W256 -> W256 -> ByteString -> LS.ByteString
lazySlice offset size bs =
  let bs' = LS.take (num size) (LS.drop (num offset) (fromStrict bs))
  in bs' <> LS.replicate ((num size) - LS.length bs') 0

parseModexpLength :: ByteString -> (W256, W256, W256)
parseModexpLength input =
  let lenb = word $ LS.toStrict $ lazySlice  0 32 input
      lene = word $ LS.toStrict $ lazySlice 32 64 input
      lenm = word $ LS.toStrict $ lazySlice 64 96 input
  in (lenb, lene, lenm)

--- checks if a range of ByteString bs starting at offset and length size is all zeros.
isZero :: W256 -> W256 -> ByteString -> Bool
isZero offset size bs =
  LS.all (== 0) $
    LS.take (num size) $
      LS.drop (num offset) $
        fromStrict bs

asInteger :: LS.ByteString -> Integer
asInteger xs = if xs == mempty then 0
  else 256 * asInteger (LS.init xs)
      + num (LS.last xs)

-- * Opcode helper actions

noop :: Monad m => m ()
noop = pure ()

pushTo :: MonadState s m => ASetter s s [a] [a] -> a -> m ()
pushTo f x = f %= (x :)

pushToSequence :: MonadState s m => ASetter s s (Seq a) (Seq a) -> a -> m ()
pushToSequence f x = f %= (Seq.|> x)

getCodeLocation :: VM -> CodeLocation
getCodeLocation vm = (view (state . contract) vm, view (state . pc) vm)

branch :: CodeLocation -> Expr EWord -> (Bool -> EVM ()) -> EVM ()
branch loc cond continue = do
  pathconds <- use constraints
  assign result . Just . VMFailure . Query $ PleaseAskSMT cond pathconds choosePath
  where
     choosePath (Case v) = do assign result Nothing
                              pushTo constraints $ if v then (cond ./= (Lit 0)) else (cond .== (Lit 0))
                              iteration <- use (iterations . at loc . non 0)
                              assign (cache . path . at (loc, iteration)) (Just v)
                              assign (iterations . at loc) (Just (iteration + 1))
                              continue v
     -- Both paths are possible; we ask for more input
     choosePath Unknown = assign result . Just . VMFailure . Choose . PleaseChoosePath cond $ choosePath . Case
     -- None of the paths are possible; fail this branch
     choosePath Inconsistent = vmError DeadPath


-- | Construct RPC Query and halt execution until resolved
fetchAccount :: Addr -> (Contract -> EVM ()) -> EVM ()
fetchAccount addr continue =
  use (env . contracts . at addr) >>= \case
    Just c -> continue c
    Nothing ->
      use (cache . fetchedContracts . at addr) >>= \case
        Just c -> do
          assign (env . contracts . at addr) (Just c)
          continue c
        Nothing -> do
          assign result . Just . VMFailure $ Query $
            PleaseFetchContract addr
              (\c -> do assign (cache . fetchedContracts . at addr) (Just c)
                        assign (env . contracts . at addr) (Just c)
                        assign result Nothing
                        continue c)

accessStorage
  :: Addr                   -- ^ Contract address
  -> Expr EWord             -- ^ Storage slot key
  -> (Expr EWord -> EVM ()) -- ^ Continuation
  -> EVM ()
accessStorage addr slot continue = do
  store <- use (env . storage)
  use (env . contracts . at addr) >>= \case
    Just c ->
      case readStorage (litAddr addr) slot store of
        -- Notice that if storage is symbolic, we always continue straight away
        Just x ->
          continue x
        Nothing ->
          if view external c
          then
            -- check if the slot is cached
            use (cache . fetchedContracts . at addr) >>= \case
              Nothing -> forceConcrete slot "cannot read symbolic slots via RPC" mkQuery
              Just _ -> forceConcrete slot "cannot read symbolic slots via rpc" $
                \s -> maybe (mkQuery s) continue (readStorage (litAddr addr) slot store)
          else do
            modifying (env . storage) (writeStorage (litAddr addr) slot (Lit 0))
            continue $ Lit 0
    Nothing ->
      fetchAccount addr $ \_ ->
        accessStorage addr slot continue
  where
      mkQuery s = assign result . Just . VMFailure . Query $
                    PleaseFetchSlot addr s
                      (\x -> do
                          modifying (cache . fetchedStorage . ix (num addr)) (Map.insert s x)
                          modifying (env . storage) (writeStorage (litAddr addr) slot (Lit x))
                          assign result Nothing
                          continue (Lit x))

accountExists :: Addr -> VM -> Bool
accountExists addr vm =
  case view (env . contracts . at addr) vm of
    Just c -> not (accountEmpty c)
    Nothing -> False

-- EIP 161
accountEmpty :: Contract -> Bool
accountEmpty c =
  case view contractcode c of
    RuntimeCode b -> null b
    _ -> False
  && (view nonce c == 0)
  && (view balance c == 0)

-- * How to finalize a transaction
finalize :: EVM ()
finalize = do
  let
    revertContracts  = use (tx . txReversion) >>= assign (env . contracts)
    revertSubstate   = assign (tx . substate) (SubState mempty mempty mempty mempty mempty)

  use result >>= \case
    Nothing ->
      error "Finalising an unfinished tx."
    Just (VMFailure (EVM.Revert _)) -> do
      revertContracts
      revertSubstate
    Just (VMFailure _) -> do
      -- burn remaining gas
      assign (state . gas) 0
      revertContracts
      revertSubstate
    Just (VMSuccess output) -> do
      -- deposit the code from a creation tx
      pc' <- use (state . pc)
      creation <- use (tx . isCreate)
      createe  <- use (state . contract)
      createeExists <- (Map.member createe) <$> use (env . contracts)
      case Expr.toList output of
        Nothing -> vmError $ UnexpectedSymbolicArg pc' "runtime code cannot have an abstract lentgh" [output]
        Just ops ->
          when (creation && createeExists) $ replaceCode createe (RuntimeCode ops)

  -- compute and pay the refund to the caller and the
  -- corresponding payment to the miner
  txOrigin     <- use (tx . origin)
  sumRefunds   <- (sum . (snd <$>)) <$> (use (tx . substate . refunds))
  miner        <- use (block . coinbase)
  blockReward  <- num . r_block <$> (use (block . schedule))
  gasPrice     <- use (tx . gasprice)
  priorityFee  <- use (tx . txPriorityFee)
  gasLimit     <- use (tx . txgaslimit)
  gasRemaining <- use (state . gas)

  let
    gasUsed      = gasLimit - gasRemaining
    cappedRefund = min (quot gasUsed 5) (num sumRefunds)
    originPay    = (num $ gasRemaining + cappedRefund) * gasPrice

    minerPay     = priorityFee * (num gasUsed)

  modifying (env . contracts)
     (Map.adjust (over balance (+ originPay)) txOrigin)
  modifying (env . contracts)
     (Map.adjust (over balance (+ minerPay)) miner)
  touchAccount miner

  -- pay out the block reward, recreating the miner if necessary
  preuse (env . contracts . ix miner) >>= \case
    Nothing -> modifying (env . contracts)
      (Map.insert miner (initialContract (EVM.RuntimeCode mempty)))
    Just _  -> noop
  modifying (env . contracts)
    (Map.adjust (over balance (+ blockReward)) miner)

  -- perform state trie clearing (EIP 161), of selfdestructs
  -- and touched accounts. addresses are cleared if they have
  --    a) selfdestructed, or
  --    b) been touched and
  --    c) are empty.
  -- (see Yellow Paper "Accrued Substate")
  --
  -- remove any destructed addresses
  destroyedAddresses <- use (tx . substate . selfdestructs)
  modifying (env . contracts)
    (Map.filterWithKey (\k _ -> (k `notElem` destroyedAddresses)))
  -- then, clear any remaining empty and touched addresses
  touchedAddresses <- use (tx . substate . touchedAccounts)
  modifying (env . contracts)
    (Map.filterWithKey
      (\k a -> not ((k `elem` touchedAddresses) && accountEmpty a)))

-- | Loads the selected contract as the current contract to execute
loadContract :: Addr -> EVM ()
loadContract target =
  preuse (env . contracts . ix target . contractcode) >>=
    \case
      Nothing ->
        error "Call target doesn't exist"
      Just targetCode -> do
        assign (state . contract) target
        assign (state . code)     targetCode
        assign (state . codeContract) target

limitStack :: Int -> EVM () -> EVM ()
limitStack n continue = do
  stk <- use (state . stack)
  if length stk + n > 1024
    then vmError EVM.StackLimitExceeded
    else continue

notStatic :: EVM () -> EVM ()
notStatic continue = do
  bad <- use (state . static)
  if bad
    then vmError StateChangeWhileStatic
    else continue

-- | Burn gas, failing if insufficient gas is available
burn :: Word64 -> EVM () -> EVM ()
burn n continue = do
  available <- use (state . gas)
  if n <= available
    then do
      state . gas -= n
      burned += n
      continue
    else
      vmError (OutOfGas available n)

--forceConcreteAddr :: SAddr -> (Addr -> EVM ()) -> EVM ()
--forceConcreteAddr n continue = case maybeLitAddr n of
  --Nothing -> vmError UnexpectedSymbolicArg
  --Just c -> continue c

forceConcrete :: Expr EWord -> String -> (W256 -> EVM ()) -> EVM ()
forceConcrete n msg continue = case maybeLitWord n of
  Nothing -> do
    vm <- get
    vmError $ UnexpectedSymbolicArg (view (state . pc) vm) msg [n]
  Just c -> continue c

forceConcrete2 :: (Expr EWord, Expr EWord) -> String -> ((W256, W256) -> EVM ()) -> EVM ()
forceConcrete2 (n,m) msg continue = case (maybeLitWord n, maybeLitWord m) of
  (Just c, Just d) -> continue (c, d)
  _ -> do
    vm <- get
    vmError $ UnexpectedSymbolicArg (view (state . pc) vm) msg [n, m]

forceConcrete3 :: (Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256) -> EVM ()) -> EVM ()
forceConcrete3 (k,n,m) msg continue = case (maybeLitWord k, maybeLitWord n, maybeLitWord m) of
  (Just c, Just d, Just f) -> continue (c, d, f)
  _ -> do
    vm <- get
    vmError $ UnexpectedSymbolicArg (view (state . pc) vm) msg [k, n, m]

forceConcrete4 :: (Expr EWord, Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256, W256) -> EVM ()) -> EVM ()
forceConcrete4 (k,l,n,m) msg continue = case (maybeLitWord k, maybeLitWord l, maybeLitWord n, maybeLitWord m) of
  (Just b, Just c, Just d, Just f) -> continue (b, c, d, f)
  _ -> do
    vm <- get
    vmError $ UnexpectedSymbolicArg (view (state . pc) vm) msg [k, l, n, m]

forceConcrete5 :: (Expr EWord, Expr EWord, Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256, W256, W256) -> EVM ()) -> EVM ()
forceConcrete5 (k,l,m,n,o) msg continue = case (maybeLitWord k, maybeLitWord l, maybeLitWord m, maybeLitWord n, maybeLitWord o) of
  (Just a, Just b, Just c, Just d, Just e) -> continue (a, b, c, d, e)
  _ -> do
    vm <- get
    vmError $ UnexpectedSymbolicArg (view (state . pc) vm) msg [k, l, m, n, o]

forceConcrete6 :: (Expr EWord, Expr EWord, Expr EWord, Expr EWord, Expr EWord, Expr EWord) -> String -> ((W256, W256, W256, W256, W256, W256) -> EVM ()) -> EVM ()
forceConcrete6 (k,l,m,n,o,p) msg continue = case (maybeLitWord k, maybeLitWord l, maybeLitWord m, maybeLitWord n, maybeLitWord o, maybeLitWord p) of
  (Just a, Just b, Just c, Just d, Just e, Just f) -> continue (a, b, c, d, e, f)
  _ -> do
    vm <- get
    vmError $ UnexpectedSymbolicArg (view (state . pc) vm) msg [k, l, m, n, o, p]

forceConcreteBuf :: Expr Buf -> String -> (ByteString -> EVM ()) -> EVM ()
forceConcreteBuf (ConcreteBuf b) _ continue = continue b
forceConcreteBuf b msg _ = do
    vm <- get
    vmError $ UnexpectedSymbolicArg (view (state . pc) vm) msg [b]

-- * Substate manipulation
refund :: Word64 -> EVM ()
refund n = do
  self <- use (state . contract)
  pushTo (tx . substate . refunds) (self, n)

unRefund :: Word64 -> EVM ()
unRefund n = do
  self <- use (state . contract)
  refs <- use (tx . substate . refunds)
  assign (tx . substate . refunds)
    (filter (\(a,b) -> not (a == self && b == n)) refs)

touchAccount :: Addr -> EVM()
touchAccount = pushTo ((tx . substate) . touchedAccounts)

selfdestruct :: Addr -> EVM()
selfdestruct = pushTo ((tx . substate) . selfdestructs)

accessAndBurn :: Addr -> EVM () -> EVM ()
accessAndBurn x cont = do
  FeeSchedule {..} <- use ( block . schedule )
  acc <- accessAccountForGas x
  let cost = if acc then g_warm_storage_read else g_cold_account_access
  burn cost cont

-- | returns a wrapped boolean- if true, this address has been touched before in the txn (warm gas cost as in EIP 2929)
-- otherwise cold
accessAccountForGas :: Addr -> EVM Bool
accessAccountForGas addr = do
  accessedAddrs <- use (tx . substate . accessedAddresses)
  let accessed = member addr accessedAddrs
  assign (tx . substate . accessedAddresses) (insert addr accessedAddrs)
  return accessed

-- | returns a wrapped boolean- if true, this slot has been touched before in the txn (warm gas cost as in EIP 2929)
-- otherwise cold
accessStorageForGas :: Addr -> Expr EWord -> EVM Bool
accessStorageForGas addr key = do
  accessedStrkeys <- use (tx . substate . accessedStorageKeys)
  case maybeLitWord key of
    Just litword -> do
      let accessed = member (addr, litword) accessedStrkeys
      assign (tx . substate . accessedStorageKeys) (insert (addr, litword) accessedStrkeys)
      return accessed
    _ -> return False

-- * Cheat codes

-- The cheat code is 7109709ecfa91a80626ff3989d68f67f5b1dd12d.
-- Call this address using one of the cheatActions below to do
-- special things, e.g. changing the block timestamp. Beware that
-- these are necessarily hevm specific.
cheatCode :: Addr
cheatCode = num (keccak' "hevm cheat code")

cheat
  :: (?op :: Word8)
  => (W256, W256) -> (W256, W256)
  -> EVM ()
cheat (inOffset, inSize) (outOffset, outSize) = do
  mem <- use (state . memory)
  vm <- get
  let
    abi = readBytes 4 (Lit inOffset) mem
    input = readMemory (Lit $ inOffset + 4) (Lit $ inSize - 4) vm
  case maybeLitWord abi of
    Nothing -> vmError $ UnexpectedSymbolicArg (view (state . pc) vm) "symbolic cheatcode selector" [abi]
    Just (fromIntegral -> abi') ->
      case Map.lookup abi' cheatActions of
        Nothing ->
          vmError (BadCheatCode (Just abi'))
        Just action -> do
            action (Lit outOffset) (Lit outSize) input
            next
            push 1

type CheatAction = Expr EWord -> Expr EWord -> Expr Buf -> EVM ()

cheatActions :: Map Word32 CheatAction
cheatActions =
  Map.fromList
    [ action "ffi(string[])" $
        \sig outOffset outSize input -> do
          vm <- get
          if view EVM.allowFFI vm then
            case decodeBuf [AbiArrayDynamicType AbiStringType] input of
              CAbi valsArr -> case valsArr of
                [AbiArrayDynamic AbiStringType strsV] ->
                  let
                    cmd = fmap
                            (\case
                              (AbiString a) -> unpack $ decodeUtf8 a
                              _ -> "")
                            (V.toList strsV)
                    cont bs = do
                      let encoded = ConcreteBuf bs
                      assign (state . returndata) encoded
                      copyBytesToMemory encoded outSize (Lit 0) outOffset
                      assign result Nothing
                  in assign result (Just . VMFailure . Query $ (PleaseDoFFI cmd cont))
                _ -> vmError (BadCheatCode sig)
              _ -> vmError (BadCheatCode sig)
          else
            let msg = encodeUtf8 "ffi disabled: run again with --ffi if you want to allow tests to call external scripts"
            in vmError . EVM.Revert . ConcreteBuf $
              abiMethod "Error(string)" (AbiTuple . V.fromList $ [AbiString msg]),

      action "warp(uint256)" $
        \sig _ _ input -> case decodeStaticArgs 0 1 input of
          [x]  -> assign (block . timestamp) x
          _ -> vmError (BadCheatCode sig),

      action "roll(uint256)" $
        \sig _ _ input -> case decodeStaticArgs 0 1 input of
          [x] -> forceConcrete x "cannot roll to a symbolic block number" (assign (block . number))
          _ -> vmError (BadCheatCode sig),

      action "store(address,bytes32,bytes32)" $
        \sig _ _ input -> case decodeStaticArgs 0 3 input of
          [a, slot, new] ->
            forceConcrete a "cannot store at a symbolic address" $ \(num -> a') ->
              fetchAccount a' $ \_ -> do
                modifying (env . storage) (writeStorage (litAddr a') slot new)
          _ -> vmError (BadCheatCode sig),

      action "load(address,bytes32)" $
        \sig outOffset _ input -> case decodeStaticArgs 0 2 input of
          [a, slot] ->
            forceConcrete a "cannot load from a symbolic address" $ \(num -> a') ->
              accessStorage a' slot $ \res -> do
                assign (state . returndata . word256At (Lit 0)) res
                assign (state . memory . word256At outOffset) res
          _ -> vmError (BadCheatCode sig),

      action "sign(uint256,bytes32)" $
        \sig outOffset _ input -> case decodeStaticArgs 0 2 input of
          [sk, hash] ->
            forceConcrete2 (sk, hash) "cannot sign symbolic data" $ \(sk', hash') -> let
              curve = getCurveByName SEC_p256k1
              priv = PrivateKey curve (num sk')
              digest = digestFromByteString (word256Bytes hash')
            in do
              case digest of
                Nothing -> vmError (BadCheatCode sig)
                Just digest' -> do
                  let s = ethsign priv digest'
                      -- calculating the V value is pretty annoying if you
                      -- don't have access to the full X/Y coords of the
                      -- signature (which we don't get back from cryptonite).
                      -- Luckily since we use a fixed nonce (to avoid the
                      -- overhead of bringing randomness into the core EVM
                      -- semantics), it would appear that every signature we
                      -- produce has v == 28. Definitely a hack, and also bad
                      -- for code that somehow depends on the value of v, but
                      -- that seems acceptable for now.
                      v = 28
                      encoded = encodeAbiValue $
                        AbiTuple (RegularVector.fromList
                          [ AbiUInt 8 v
                          , AbiBytes 32 (word256Bytes . fromInteger $ sign_r s)
                          , AbiBytes 32 (word256Bytes . fromInteger $ sign_s s)
                          ])
                  assign (state . returndata) (ConcreteBuf encoded)
                  copyBytesToMemory (ConcreteBuf encoded) (Lit . num . BS.length $ encoded) (Lit 0) outOffset
          _ -> vmError (BadCheatCode sig),

      action "addr(uint256)" $
        \sig outOffset _ input -> case decodeStaticArgs 0 1 input of
          [sk] -> forceConcrete sk "cannot derive address for a symbolic key" $ \sk' -> let
                curve = getCurveByName SEC_p256k1
                pubPoint = generateQ curve (num sk')
                encodeInt = encodeAbiValue . AbiUInt 256 . fromInteger
              in do
                case pubPoint of
                  PointO -> do vmError (BadCheatCode sig)
                  Point x y -> do
                    -- See yellow paper #286
                    let
                      pub = BS.concat [ encodeInt x, encodeInt y ]
                      addr = Lit . W256 . word256 . BS.drop 12 . BS.take 32 . keccakBytes $ pub
                    assign (state . returndata . word256At (Lit 0)) addr
                    assign (state . memory . word256At outOffset) addr
          _ -> vmError (BadCheatCode sig)

    ]
  where
    action s f = (abiKeccak s, f (Just $ abiKeccak s))

-- | We don't wanna introduce the machinery needed to sign with a random nonce,
-- so we just use the same nonce every time (420). This is obviusly very
-- insecure, but fine for testing purposes.
ethsign :: PrivateKey -> Digest Crypto.Keccak_256 -> Signature
ethsign sk digest = go 420
  where
    go k = case signDigestWith k sk digest of
       Nothing  -> go (k + 1)
       Just sig -> sig

-- * General call implementation ("delegateCall")
-- note that the continuation is ignored in the precompile case
delegateCall
  :: (?op :: Word8)
  => Contract -> Word64 -> Expr EWord -> Expr EWord -> W256 -> W256 -> W256 -> W256 -> W256
  -> [Expr EWord]
  -> (Addr -> EVM ())
  -> EVM ()
delegateCall this gasGiven xTo xContext xValue xInOffset xInSize xOutOffset xOutSize xs continue =
  forceConcrete2 (xTo, xContext) "cannot delegateCall with symbolic target or context" $
    \((num -> xTo'), (num -> xContext')) ->
      if xTo' > 0 && xTo' <= 9
      then precompiledContract this gasGiven xTo' xContext' xValue xInOffset xInSize xOutOffset xOutSize xs
      else if xTo' == cheatCode then
        do
          assign (state . stack) xs
          cheat (xInOffset, xInSize) (xOutOffset, xOutSize)
      else
        callChecks this gasGiven xContext' xTo' xValue xInOffset xInSize xOutOffset xOutSize xs $
        \xGas -> do
          vm0 <- get
          fetchAccount xTo' $ \target ->
                burn xGas $ do
                  let newContext = CallContext
                                    { callContextTarget    = xTo'
                                    , callContextContext   = xContext'
                                    , callContextOffset    = xOutOffset
                                    , callContextSize      = xOutSize
                                    , callContextCodehash  = view codehash target
                                    , callContextReversion = (view (env . contracts) vm0, view (env . storage) vm0)
                                    , callContextSubState  = view (tx . substate) vm0
                                    , callContextAbi =
                                        if xInSize >= 4
                                        then case unlit $ readBytes 4 (Lit xInOffset) (view (state . memory) vm0)
                                             of Nothing -> Nothing
                                                Just abi -> Just $ num abi
                                        else Nothing
                                    , callContextData = (readMemory (Lit xInOffset) (Lit xInSize) vm0)
                                    }

                  pushTrace (FrameTrace newContext)
                  next
                  vm1 <- get

                  pushTo frames $ Frame
                    { _frameState = (set stack xs) (view state vm1)
                    , _frameContext = newContext
                    }

                  let clearInitCode = \case
                        (InitCode _ _) -> InitCode mempty mempty
                        a -> a

                  zoom state $ do
                    assign gas (num xGas)
                    assign pc 0
                    assign code (clearInitCode (view contractcode target))
                    assign codeContract xTo'
                    assign stack mempty
                    assign memory mempty
                    assign memorySize 0
                    assign returndata mempty
                    assign calldata (copySlice (Lit xInOffset) (Lit 0) (Lit xInSize) (view (state . memory) vm0) mempty)

                  continue xTo'

-- -- * Contract creation

-- EIP 684
collision :: Maybe Contract -> Bool
collision c' = case c' of
  Just c -> (view nonce c /= 0) || case view contractcode c of
    RuntimeCode b -> not $ null b
    _ -> True
  Nothing -> False

create :: (?op :: Word8)
  => Addr -> Contract
  -> Word64 -> W256 -> [Expr EWord] -> Addr -> Expr Buf -> EVM ()
create self this xGas' xValue xs newAddr initCode = do
  vm0 <- get
  let xGas = num xGas'
  if view nonce this == num (maxBound :: Word64)
  then do
    assign (state . stack) (Lit 0 : xs)
    assign (state . returndata) mempty
    pushTrace $ ErrorTrace NonceOverflow
    next
  else if xValue > view balance this
  then do
    assign (state . stack) (Lit 0 : xs)
    assign (state . returndata) mempty
    pushTrace $ ErrorTrace $ BalanceTooLow xValue (view balance this)
    next
  else if length (view frames vm0) >= 1024
  then do
    assign (state . stack) (Lit 0 : xs)
    assign (state . returndata) mempty
    pushTrace $ ErrorTrace CallDepthLimitReached
    next
  else if collision $ view (env . contracts . at newAddr) vm0
  then burn xGas $ do
    assign (state . stack) (Lit 0 : xs)
    assign (state . returndata) mempty
    modifying (env . contracts . ix self . nonce) succ
    next
  else burn xGas $ do
    touchAccount self
    touchAccount newAddr
    let
    -- unfortunately we have to apply some (pretty hacky)
    -- heuristics here to parse the unstructured buffer read
    -- from memory into a code and data section
    -- TODO: comment explaining whats going on here
    let contract' = do
          prefixLen <- Expr.concPrefix initCode
          prefix <- Expr.toList $ Expr.take (num prefixLen) initCode
          let sym = Expr.drop (num prefixLen) initCode
          conc <- mapM unlitByte prefix
          pure $ InitCode (BS.pack $ V.toList conc) sym
    case contract' of
      Nothing ->
        vmError $ UnexpectedSymbolicArg (view (state . pc) vm0) "initcode must have a concrete prefix" []
      Just c -> do
        let
          newContract = initialContract c
          newContext  =
            CreationContext { creationContextAddress   = newAddr
                            , creationContextCodehash  = view codehash newContract
                            , creationContextReversion = view (env . contracts) vm0
                            , creationContextSubstate  = view (tx . substate) vm0
                            }

        zoom (env . contracts) $ do
          oldAcc <- use (at newAddr)
          let oldBal = maybe 0 (view balance) oldAcc

          assign (at newAddr) (Just (newContract & balance .~ oldBal))
          modifying (ix self . nonce) succ

        let resetStorage = \case
              ConcreteStore s -> ConcreteStore (Map.delete (num newAddr) s)
              AbstractStore -> AbstractStore
              EmptyStore -> EmptyStore
              SStore {} -> error "trying to reset symbolic storage with writes in create"
              GVar _  -> error "unexpected global variable"

        modifying (env . storage) resetStorage
        modifying (env . origStorage) (Map.delete (num newAddr))

        transfer self newAddr xValue

        pushTrace (FrameTrace newContext)
        next
        vm1 <- get
        pushTo frames $ Frame
          { _frameContext = newContext
          , _frameState   = (set stack xs) (view state vm1)
          }

        assign state $
          blankState
            & set contract   newAddr
            & set codeContract newAddr
            & set code       c
            & set callvalue  (Lit xValue)
            & set caller     (litAddr self)
            & set gas        xGas'

-- | Replace a contract's code, like when CREATE returns
-- from the constructor code.
replaceCode :: Addr -> ContractCode -> EVM ()
replaceCode target newCode =
  zoom (env . contracts . at target) $
    get >>= \case
      Just now -> case (view contractcode now) of
        InitCode _ _ ->
          put . Just $
          initialContract newCode
          & set balance (view balance now)
          & set nonce   (view nonce now)
        RuntimeCode _ ->
          error ("internal error: can't replace code of deployed contract " <> show target)
      Nothing ->
        error "internal error: can't replace code of nonexistent contract"

replaceCodeOfSelf :: ContractCode -> EVM ()
replaceCodeOfSelf newCode = do
  vm <- get
  replaceCode (view (state . contract) vm) newCode

resetState :: EVM ()
resetState = do
  assign result Nothing
  assign frames []
  assign state  blankState


-- * VM error implementation

vmError :: Error -> EVM ()
vmError e = finishFrame (FrameErrored e)

underrun :: EVM ()
underrun = vmError StackUnderrun

-- | A stack frame can be popped in three ways.
data FrameResult
  = FrameReturned (Expr Buf) -- ^ STOP, RETURN, or no more code
  | FrameReverted (Expr Buf) -- ^ REVERT
  | FrameErrored Error -- ^ Any other error
  deriving Show

-- | This function defines how to pop the current stack frame in either of
-- the ways specified by 'FrameResult'.
--
-- It also handles the case when the current stack frame is the only one;
-- in this case, we set the final '_result' of the VM execution.
finishFrame :: FrameResult -> EVM ()
finishFrame how = do
  oldVm <- get

  case view frames oldVm of
    -- Is the current frame the only one?
    [] -> do
      case how of
          FrameReturned output -> assign result . Just $ VMSuccess output
          FrameReverted buffer -> assign result . Just $ VMFailure (EVM.Revert buffer)
          FrameErrored e       -> assign result . Just $ VMFailure e
      finalize

    -- Are there some remaining frames?
    nextFrame : remainingFrames -> do

      -- Insert a debug trace.
      insertTrace $
        case how of
          FrameErrored e ->
            ErrorTrace e
          FrameReverted e ->
            ErrorTrace (EVM.Revert e)
          FrameReturned output ->
            ReturnTrace output (view frameContext nextFrame)
      -- Pop to the previous level of the debug trace stack.
      popTrace

      -- Pop the top frame.
      assign frames remainingFrames
      -- Install the state of the frame to which we shall return.
      assign state (view frameState nextFrame)

      -- When entering a call, the gas allowance is counted as burned
      -- in advance; this unburns the remainder and adds it to the
      -- parent frame.
      let remainingGas = view (state . gas) oldVm
          reclaimRemainingGasAllowance = do
            modifying burned (subtract remainingGas)
            modifying (state . gas) (+ remainingGas)

      -- Now dispatch on whether we were creating or calling,
      -- and whether we shall return, revert, or error (six cases).
      case view frameContext nextFrame of

        -- Were we calling?
        CallContext _ _ (Lit -> outOffset) (Lit -> outSize) _ _ _ reversion substate' -> do

          -- Excerpt K.1. from the yellow paper:
          -- K.1. Deletion of an Account Despite Out-of-gas.
          -- At block 2675119, in the transaction 0xcf416c536ec1a19ed1fb89e4ec7ffb3cf73aa413b3aa9b77d60e4fd81a4296ba,
          -- an account at address 0x03 was called and an out-of-gas occurred during the call.
          -- Against the equation (197), this added 0x03 in the set of touched addresses, and this transaction turned σ[0x03] into ∅.

          -- In other words, we special case address 0x03 and keep it in the set of touched accounts during revert
          touched <- use (tx . substate . touchedAccounts)

          let
            substate'' = over touchedAccounts (maybe id cons (find (3 ==) touched)) substate'
            (contractsReversion, storageReversion) = reversion
            revertContracts = assign (env . contracts) contractsReversion
            revertStorage = assign (env . storage) storageReversion
            revertSubstate  = assign (tx . substate) substate''

          case how of
            -- Case 1: Returning from a call?
            FrameReturned output -> do
              assign (state . returndata) output
              copyCallBytesToMemory output outSize (Lit 0) outOffset
              reclaimRemainingGasAllowance
              push 1

            -- Case 2: Reverting during a call?
            FrameReverted output -> do
              revertContracts
              revertStorage
              revertSubstate
              assign (state . returndata) output
              copyCallBytesToMemory output outSize (Lit 0) outOffset
              reclaimRemainingGasAllowance
              push 0

            -- Case 3: Error during a call?
            FrameErrored _ -> do
              revertContracts
              revertStorage
              revertSubstate
              assign (state . returndata) mempty
              push 0
        -- Or were we creating?
        CreationContext _ _ reversion substate' -> do
          creator <- use (state . contract)
          let
            createe = view (state . contract) oldVm
            revertContracts = assign (env . contracts) reversion'
            revertSubstate  = assign (tx . substate) substate'

            -- persist the nonce through the reversion
            reversion' = (Map.adjust (over nonce (+ 1)) creator) reversion

          case how of
            -- Case 4: Returning during a creation?
            FrameReturned output -> do
                case Expr.toList output of
                  Nothing -> vmError $
                    UnexpectedSymbolicArg
                      (view (state . pc) oldVm)
                      "runtime code cannot have an abstract length"
                      [output]
                  Just newCode -> do
                    replaceCode createe (RuntimeCode newCode)
                    assign (state . returndata) mempty
                    reclaimRemainingGasAllowance
                    push (num createe)

            -- Case 5: Reverting during a creation?
            FrameReverted output -> do
              revertContracts
              revertSubstate
              assign (state . returndata) output
              reclaimRemainingGasAllowance
              push 0

            -- Case 6: Error during a creation?
            FrameErrored _ -> do
              revertContracts
              revertSubstate
              assign (state . returndata) mempty
              push 0


-- * Memory helpers

accessUnboundedMemoryRange
  :: FeeSchedule Word64
  -> Word64
  -> Word64
  -> EVM ()
  -> EVM ()
accessUnboundedMemoryRange _ _ 0 continue = continue
accessUnboundedMemoryRange fees f l continue = do
  m0 <- num <$> use (state . memorySize)
  do
    let m1 = 32 * ceilDiv (max m0 (f + l)) 32
    burn (memoryCost fees m1 - memoryCost fees m0) $ do
      assign (state . memorySize) m1
      continue

accessMemoryRange
  :: FeeSchedule Word64
  -> W256
  -> W256
  -> EVM ()
  -> EVM ()
accessMemoryRange _ _ 0 continue = continue
accessMemoryRange fees f l continue =
  case (,) <$> toWord64 f <*> toWord64 l of
    Nothing -> vmError IllegalOverflow
    Just (f64, l64) ->
      if f64 + l64 < l64
        then vmError IllegalOverflow
        else accessUnboundedMemoryRange fees f64 l64 continue

accessMemoryWord
  :: FeeSchedule Word64 -> W256 -> EVM () -> EVM ()
accessMemoryWord fees x = accessMemoryRange fees x 32

copyBytesToMemory
  :: Expr Buf -> Expr EWord -> Expr EWord -> Expr EWord -> EVM ()
copyBytesToMemory bs size xOffset yOffset =
  if size == (Lit 0) then noop
  else do
    mem <- use (state . memory)
    assign (state . memory) $
      copySlice xOffset yOffset size bs mem

copyCallBytesToMemory
  :: Expr Buf -> Expr EWord -> Expr EWord -> Expr EWord -> EVM ()
copyCallBytesToMemory bs size xOffset yOffset =
  if size == (Lit 0) then noop
  else do
    mem <- use (state . memory)
    assign (state . memory) $
      copySlice xOffset yOffset (Expr.min size (bufLength bs)) bs mem

readMemory :: Expr EWord -> Expr EWord -> VM -> Expr Buf
readMemory offset size vm = copySlice offset (Lit 0) size (view (state . memory) vm) mempty

-- * Tracing

withTraceLocation
  :: (MonadState VM m) => TraceData -> m Trace
withTraceLocation x = do
  vm <- get
  let
    Just this =
      currentContract vm
  pure Trace
    { _traceData = x
    , _traceContract = this
    , _traceOpIx = fromMaybe 0 $ (view opIxMap this) Vector.!? (view (state . pc) vm)
    }

pushTrace :: TraceData -> EVM ()
pushTrace x = do
  trace <- withTraceLocation x
  modifying traces $
    \t -> Zipper.children $ Zipper.insert (Node trace []) t

insertTrace :: TraceData -> EVM ()
insertTrace x = do
  trace <- withTraceLocation x
  modifying traces $
    \t -> Zipper.nextSpace $ Zipper.insert (Node trace []) t

popTrace :: EVM ()
popTrace =
  modifying traces $
    \t -> case Zipper.parent t of
            Nothing -> error "internal error (trace root)"
            Just t' -> Zipper.nextSpace t'

zipperRootForest :: Zipper.TreePos Zipper.Empty a -> Forest a
zipperRootForest z =
  case Zipper.parent z of
    Nothing -> Zipper.toForest z
    Just z' -> zipperRootForest (Zipper.nextSpace z')

traceForest :: VM -> Forest Trace
traceForest = view (traces . to zipperRootForest)

traceTopLog :: (MonadState VM m) => [Expr Log] -> m ()
traceTopLog [] = noop
traceTopLog ((LogEntry addr bytes topics) : _) = do
  trace <- withTraceLocation (EventTrace addr bytes topics)
  modifying traces $
    \t -> Zipper.nextSpace (Zipper.insert (Node trace []) t)
traceTopLog ((GVar _) : _) = error "unexpected global variable"

-- * Stack manipulation

push :: W256 -> EVM ()
push = pushSym . Lit

pushSym :: Expr EWord -> EVM ()
pushSym x = state . stack %= (x :)


stackOp1
  :: (?op :: Word8)
  => ((Expr EWord) -> Word64)
  -> ((Expr EWord) -> (Expr EWord))
  -> EVM ()
stackOp1 cost f =
  use (state . stack) >>= \case
    (x:xs) ->
      burn (cost x) $ do
        next
        let !y = f x
        state . stack .= y : xs
    _ ->
      underrun

stackOp2
  :: (?op :: Word8)
  => (((Expr EWord), (Expr EWord)) -> Word64)
  -> (((Expr EWord), (Expr EWord)) -> (Expr EWord))
  -> EVM ()
stackOp2 cost f =
  use (state . stack) >>= \case
    (x:y:xs) ->
      burn (cost (x, y)) $ do
        next
        state . stack .= f (x, y) : xs
    _ ->
      underrun

stackOp3
  :: (?op :: Word8)
  => (((Expr EWord), (Expr EWord), (Expr EWord)) -> Word64)
  -> (((Expr EWord), (Expr EWord), (Expr EWord)) -> (Expr EWord))
  -> EVM ()
stackOp3 cost f =
  use (state . stack) >>= \case
    (x:y:z:xs) ->
      burn (cost (x, y, z)) $ do
      next
      state . stack .= f (x, y, z) : xs
    _ ->
      underrun

-- * Bytecode data functions

checkJump :: (Integral n) => n -> [Expr EWord] -> EVM ()
checkJump x xs = do
  theCode <- use (state . code)
  self <- use (state . codeContract)
  theCodeOps <- use (env . contracts . ix self . codeOps)
  theOpIxMap <- use (env . contracts . ix self . opIxMap)
  let ops = case theCode of
        InitCode ops' _ -> V.fromList $ LitByte <$> BS.unpack ops'
        RuntimeCode ops' -> ops'
      op = do
        -- TODO: not a big fan of how bounds are checked, change this
        b <- if x < num (length ops) then ops V.!? num x else Nothing
        unlitByte b
  case op of
    Nothing -> vmError EVM.BadJumpDestination
    Just b ->
      if 0x5b == b && OpJumpdest == snd (theCodeOps RegularVector.! (theOpIxMap Vector.! num x))
         then do
           state . stack .= xs
           state . pc .= num x
         else
           vmError EVM.BadJumpDestination

opSize :: Word8 -> Int
opSize x | x >= 0x60 && x <= 0x7f = num x - 0x60 + 2
opSize _                          = 1

--  i of the resulting vector contains the operation index for
-- the program counter value i.  This is needed because source map
-- entries are per operation, not per byte.
mkOpIxMap :: ContractCode -> Vector Int
mkOpIxMap (InitCode conc _)
  = Vector.create $ Vector.new (BS.length conc) >>= \v ->
      -- Loop over the byte string accumulating a vector-mutating action.
      -- This is somewhat obfuscated, but should be fast.
      let (_, _, _, m) = BS.foldl' (go v) (0 :: Word8, 0, 0, return ()) conc
      in m >> return v
      where
        -- concrete case
        go v (0, !i, !j, !m) x | x >= 0x60 && x <= 0x7f =
          {- Start of PUSH op. -} (x - 0x60 + 1, i + 1, j,     m >> Vector.write v i j)
        go v (1, !i, !j, !m) _ =
          {- End of PUSH op. -}   (0,            i + 1, j + 1, m >> Vector.write v i j)
        go v (0, !i, !j, !m) _ =
          {- Other op. -}         (0,            i + 1, j + 1, m >> Vector.write v i j)
        go v (n, !i, !j, !m) _ =
          {- PUSH data. -}        (n - 1,        i + 1, j,     m >> Vector.write v i j)

mkOpIxMap (RuntimeCode ops)
  = Vector.create $ Vector.new (length ops) >>= \v ->
      let (_, _, _, m) = foldl (go v) (0, 0, 0, return ()) (stripBytecodeMetadataSym $ V.toList ops)
      in m >> return v
      where
        go v (0, !i, !j, !m) x = case unlitByte x of
          Just x' -> if x' >= 0x60 && x' <= 0x7f
            -- start of PUSH op --
                     then (x' - 0x60 + 1, i + 1, j,     m >> Vector.write v i j)
            -- other data --
                     else (0,             i + 1, j + 1, m >> Vector.write v i j)
          _ -> error $ "cannot analyze symbolic code:\nx: " <> show x <> " i: " <> show i <> " j: " <> show j

        go v (1, !i, !j, !m) _ =
          {- End of PUSH op. -}   (0,            i + 1, j + 1, m >> Vector.write v i j)
        go v (n, !i, !j, !m) _ =
          {- PUSH data. -}        (n - 1,        i + 1, j,     m >> Vector.write v i j)


vmOp :: VM -> Maybe Op
vmOp vm =
  let i  = vm ^. state . pc
      code' = vm ^. state . code
      (op, pushdata) = case code' of
        InitCode xs' _ ->
          (BS.index xs' i, fmap LitByte $ BS.unpack $ BS.drop i xs')
        RuntimeCode xs' ->
          ( fromMaybe (error "unexpected symbolic code") . unlitByte $ xs' V.! i , V.toList $ V.drop i xs')
  in if (opslen code' < i)
     then Nothing
     else Just (readOp op pushdata)

vmOpIx :: VM -> Maybe Int
vmOpIx vm =
  do self <- currentContract vm
     (view opIxMap self) Vector.!? (view (state . pc) vm)

opParams :: VM -> Map String (Expr EWord)
opParams vm =
  case vmOp vm of
    Just OpCreate ->
      params $ words "value offset size"
    Just OpCall ->
      params $ words "gas to value in-offset in-size out-offset out-size"
    Just OpSstore ->
      params $ words "index value"
    Just OpCodecopy ->
      params $ words "mem-offset code-offset code-size"
    Just OpSha3 ->
      params $ words "offset size"
    Just OpCalldatacopy ->
      params $ words "to from size"
    Just OpExtcodecopy ->
      params $ words "account mem-offset code-offset code-size"
    Just OpReturn ->
      params $ words "offset size"
    Just OpJumpi ->
      params $ words "destination condition"
    _ -> mempty
  where
    params xs =
      if length (vm ^. state . stack) >= length xs
      then Map.fromList (zip xs (vm ^. state . stack))
      else mempty

-- | Reads
readOp :: Word8 -> [Expr Byte] -> Op
readOp x _  | x >= 0x80 && x <= 0x8f = OpDup (x - 0x80 + 1)
readOp x _  | x >= 0x90 && x <= 0x9f = OpSwap (x - 0x90 + 1)
readOp x _  | x >= 0xa0 && x <= 0xa4 = OpLog (x - 0xa0)
readOp x xs | x >= 0x60 && x <= 0x7f =
  let n = num $ x - 0x60 + 1
  in OpPush (readBytes n (Lit 0) (Expr.fromList $ V.fromList xs))
readOp x _ = case x of
  0x00 -> OpStop
  0x01 -> OpAdd
  0x02 -> OpMul
  0x03 -> OpSub
  0x04 -> OpDiv
  0x05 -> OpSdiv
  0x06 -> OpMod
  0x07 -> OpSmod
  0x08 -> OpAddmod
  0x09 -> OpMulmod
  0x0a -> OpExp
  0x0b -> OpSignextend
  0x10 -> OpLt
  0x11 -> OpGt
  0x12 -> OpSlt
  0x13 -> OpSgt
  0x14 -> OpEq
  0x15 -> OpIszero
  0x16 -> OpAnd
  0x17 -> OpOr
  0x18 -> OpXor
  0x19 -> OpNot
  0x1a -> OpByte
  0x1b -> OpShl
  0x1c -> OpShr
  0x1d -> OpSar
  0x20 -> OpSha3
  0x30 -> OpAddress
  0x31 -> OpBalance
  0x32 -> OpOrigin
  0x33 -> OpCaller
  0x34 -> OpCallvalue
  0x35 -> OpCalldataload
  0x36 -> OpCalldatasize
  0x37 -> OpCalldatacopy
  0x38 -> OpCodesize
  0x39 -> OpCodecopy
  0x3a -> OpGasprice
  0x3b -> OpExtcodesize
  0x3c -> OpExtcodecopy
  0x3d -> OpReturndatasize
  0x3e -> OpReturndatacopy
  0x3f -> OpExtcodehash
  0x40 -> OpBlockhash
  0x41 -> OpCoinbase
  0x42 -> OpTimestamp
  0x43 -> OpNumber
  0x44 -> OpPrevRandao
  0x45 -> OpGaslimit
  0x46 -> OpChainid
  0x47 -> OpSelfbalance
  0x50 -> OpPop
  0x51 -> OpMload
  0x52 -> OpMstore
  0x53 -> OpMstore8
  0x54 -> OpSload
  0x55 -> OpSstore
  0x56 -> OpJump
  0x57 -> OpJumpi
  0x58 -> OpPc
  0x59 -> OpMsize
  0x5a -> OpGas
  0x5b -> OpJumpdest
  0xf0 -> OpCreate
  0xf1 -> OpCall
  0xf2 -> OpCallcode
  0xf3 -> OpReturn
  0xf4 -> OpDelegatecall
  0xf5 -> OpCreate2
  0xfd -> OpRevert
  0xfa -> OpStaticcall
  0xff -> OpSelfdestruct
  _    -> OpUnknown x

-- Maps operation indicies into a pair of (bytecode index, operation)
mkCodeOps :: ContractCode -> RegularVector.Vector (Int, Op)
mkCodeOps (InitCode bytes _) = RegularVector.fromList . toList $ go 0 bytes
  where
    go !i !xs =
      case BS.uncons xs of
        Nothing ->
          mempty
        Just (x, xs') ->
          let j = opSize x
          in (i, readOp x (fmap LitByte $ BS.unpack xs')) Seq.<| go (i + j) (BS.drop j xs)
mkCodeOps (RuntimeCode ops) = RegularVector.fromList . toList $ go' 0 (stripBytecodeMetadataSym $ V.toList ops)
  where
    go' !i !xs =
      case uncons xs of
        Nothing ->
          mempty
        Just (x, xs') ->
          let x' = fromMaybe (error "unexpected symbolic code argument") $ unlitByte x
              j = opSize x'
          in (i, readOp x' xs') Seq.<| go' (i + j) (drop j xs)

-- * Gas cost calculation helpers

-- Gas cost function for CALL, transliterated from the Yellow Paper.
costOfCall
  :: FeeSchedule Word64
  -> Bool -> W256 -> Word64 -> Word64 -> Addr
  -> EVM (Word64, Word64)
costOfCall (FeeSchedule {..}) recipientExists xValue availableGas xGas target = do
  acc <- accessAccountForGas target
  let call_base_gas = if acc then g_warm_storage_read else g_cold_account_access
      c_new = if not recipientExists && xValue /= 0
            then g_newaccount
            else 0
      c_xfer = if xValue /= 0  then num g_callvalue else 0
      c_extra = call_base_gas + c_xfer + c_new
      c_gascap =  if availableGas >= c_extra
                  then min xGas (allButOne64th (availableGas - c_extra))
                  else xGas
      c_callgas = if xValue /= 0 then c_gascap + g_callstipend else c_gascap
  return (c_gascap + c_extra, c_callgas)

-- Gas cost of create, including hash cost if needed
costOfCreate
  :: FeeSchedule Word64
  -> Word64 -> W256 -> (Word64, Word64)
costOfCreate (FeeSchedule {..}) availableGas hashSize =
  (createCost + initGas, initGas)
  where
    createCost = g_create + hashCost
    hashCost   = g_sha3word * ceilDiv (num hashSize) 32
    initGas    = allButOne64th (availableGas - createCost)

concreteModexpGasFee :: ByteString -> Word64
concreteModexpGasFee input =
  if lenb < num (maxBound :: Word32) &&
     (lene < num (maxBound :: Word32) || (lenb == 0 && lenm == 0)) &&
     lenm < num (maxBound :: Word64)
  then
    max 200 ((multiplicationComplexity * iterCount) `div` 3)
  else
    maxBound -- TODO: this is not 100% correct, return Nothing on overflow
  where (lenb, lene, lenm) = parseModexpLength input
        ez = isZero (96 + lenb) lene input
        e' = word $ LS.toStrict $
          lazySlice (96 + lenb) (min 32 lene) input
        nwords :: Word64
        nwords = ceilDiv (num $ max lenb lenm) 8
        multiplicationComplexity = nwords * nwords
        iterCount' :: Word64
        iterCount' | lene <= 32 && ez = 0
                   | lene <= 32 = num (log2 e')
                   | e' == 0 = 8 * (num lene - 32)
                   | otherwise = num (log2 e') + 8 * (num lene - 32)
        iterCount = max iterCount' 1

-- Gas cost of precompiles
costOfPrecompile :: FeeSchedule Word64 -> Addr -> Expr Buf -> Word64
costOfPrecompile (FeeSchedule {..}) precompileAddr input =
  let errorDynamicSize = error "precompile input cannot have a dynamic size"
      inputLen = case input of
                   ConcreteBuf bs -> fromIntegral $ BS.length bs
                   AbstractBuf _ -> errorDynamicSize
                   buf -> case bufLength buf of
                            Lit l -> num l -- TODO: overflow
                            _ -> errorDynamicSize
  in case precompileAddr of
    -- ECRECOVER
    0x1 -> 3000
    -- SHA2-256
    0x2 -> num $ (((inputLen + 31) `div` 32) * 12) + 60
    -- RIPEMD-160
    0x3 -> num $ (((inputLen + 31) `div` 32) * 120) + 600
    -- IDENTITY
    0x4 -> num $ (((inputLen + 31) `div` 32) * 3) + 15
    -- MODEXP
    0x5 -> case input of
             ConcreteBuf i -> concreteModexpGasFee i
             _ -> error "Unsupported symbolic modexp gas calc "
    -- ECADD
    0x6 -> g_ecadd
    -- ECMUL
    0x7 -> g_ecmul
    -- ECPAIRING
    0x8 -> (inputLen `div` 192) * g_pairing_point + g_pairing_base
    -- BLAKE2
    0x9 -> case input of
             ConcreteBuf i -> g_fround * (num $ asInteger $ lazySlice 0 4 i)
             _ -> error "Unsupported symbolic blake2 gas calc"
    _ -> error ("unimplemented precompiled contract " ++ show precompileAddr)

-- Gas cost of memory expansion
memoryCost :: FeeSchedule Word64 -> Word64 -> Word64
memoryCost FeeSchedule{..} byteCount =
  let
    wordCount = ceilDiv byteCount 32
    linearCost = g_memory * wordCount
    quadraticCost = div (wordCount * wordCount) 512
  in
    linearCost + quadraticCost

-- * Arithmetic

ceilDiv :: (Num a, Integral a) => a -> a -> a
ceilDiv m n = div (m + n - 1) n

allButOne64th :: (Num a, Integral a) => a -> a
allButOne64th n = n - div n 64

log2 :: FiniteBits b => b -> Int
log2 x = finiteBitSize x - 1 - countLeadingZeros x

hashcode :: ContractCode -> Expr EWord
hashcode (InitCode ops args) = keccak $ (ConcreteBuf ops) <> args
hashcode (RuntimeCode ops) = keccak . Expr.fromList $ ops

-- | The length of the code ignoring any constructor args.
-- This represents the region that can contain executable opcodes
opslen :: ContractCode -> Int
opslen (InitCode ops _) = BS.length ops
opslen (RuntimeCode ops) = length ops

-- | The length of the code including any constructor args.
-- This can return an abstract value
codelen :: ContractCode -> Expr EWord
codelen c@(InitCode {}) = bufLength $ toBuf c
codelen (RuntimeCode ops) = Lit . num $ length ops

toBuf :: ContractCode -> Expr Buf
toBuf (InitCode ops args) = ConcreteBuf ops <> args
toBuf (RuntimeCode ops) = Expr.fromList ops


codeloc :: EVM CodeLocation
codeloc = do
  vm <- get
  let self = view (state . contract) vm
      loc = view (state . pc) vm
  pure (self, loc)

toWord64 :: W256 -> Maybe Word64
toWord64 n =
  if n <= num (maxBound :: Word64)
    then let (W256 (Word256 _ (Word128 _ n'))) = n in Just n'
    else Nothing

-- * Emacs setup

-- Local Variables:
-- outline-regexp: "-- \\*+\\|data \\|newtype \\|type \\| +-- op: "
-- outline-heading-alist:
--   (("-- *" . 1) ("data " . 2) ("newtype " . 2) ("type " . 2))
-- compile-command: "make"
-- End:
