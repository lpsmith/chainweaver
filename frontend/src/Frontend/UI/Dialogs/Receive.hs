{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Dialog for displaying account information required for receiving transfers
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.Receive
  ( uiReceiveModal
  ) where

import Control.Applicative (liftA2)
import Control.Lens ((^.), (<>~), _1)
import Control.Monad (void, (<=<))
import Control.Error (hush, headMay)

import Data.Bifunctor (first)
import Data.Either (isLeft,rights)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Decimal (Decimal)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Aeson as Aeson
import qualified Data.HashMap.Lazy as HM

import Reflex
import Reflex.Dom

import Kadena.SigningApi (DappCap (..))
import Pact.Types.Capability (SigCapability (..))
import Pact.Types.Term (QualifiedName (..), KeySet (..), Name (..), BareName (..))
import Pact.Types.ChainId (ChainId(..))
import Pact.Types.ChainMeta (PublicMeta (..), TTLSeconds)
import Pact.Types.PactValue (PactValue (..))
import Pact.Types.Exp (Literal (LString, LDecimal))
import Pact.Types.Command (Command)
import Pact.Types.Runtime (GasLimit)
import qualified Pact.Types.Scheme as PactScheme
import Language.Javascript.JSaddle.Types (MonadJSM)

import Frontend.Crypto.Class (GenKeyArg (..), HasCrypto, cryptoGenPubKeyFromPrivate, cryptoGenKey)
import Common.Wallet (parsePublicKey,toPactPublicKey)

import Frontend.Foundation
import Frontend.KadenaAddress
import Frontend.Network
import Frontend.UI.Dialogs.NetworkEdit

import Frontend.UI.Dialogs.DeployConfirmation (CanSubmitTransaction, TransactionSubmitFeedback (..), submitTransactionWithFeedback)

import Frontend.UI.DeploymentSettings (uiMetaData, userChainIdSelect, defaultGASCapability)

import Frontend.UI.Modal
import Frontend.UI.Widgets
import Frontend.UI.Widgets.AccountName (uiAccountNameInput)
import Frontend.Wallet

data LegacyTransferInfo key = LegacyTransferInfo
  { _legacyTransferInfo_account :: AccountName
  , _legacyTransferInfo_chainId :: ChainId
  , _legacyTransferInfo_amount :: Decimal
  , _legacyTransferInfo_keyPair :: (key, PublicKey)
  }

data ReceiveBuildCommandInfo key = ReceiveBuildCommandInfo
  { _receiveBuildCommandInfo_code :: Text
  , _receiveBuildCommandInfo_transferInfo :: LegacyTransferInfo key
  , _receiveBuildCommandInfo_command :: Command Text
  , _receiveBuildCommandInfo_signingPairs :: [KeyPair key]
  , _receiveBuildCommandInfo_publicMeta :: PublicMeta
  , _receiveBuildCommandInfo_capabilities :: [DappCap]
  , _receiveBuildCommandInfo_assignedCaps :: Map PublicKey [SigCapability]
  , _receiveBuildCommandInfo_payload :: Aeson.Object
  }

uiDisplayAddress
  :: ( MonadJSM (Performable m)
     , DomBuilder t m
     , PostBuild t m
     , PerformEvent t m
     )
  => Text
  -> m ()
uiDisplayAddress address = do
  elClass "h2" "heading heading_type_h2" $ text "Kadena Address"
  divClass "group" $ do
    -- Kadena Address
    divClass "segment segment_type_tertiary labeled-input account-details__kadena-address-wrapper" $ do
      void $ uiInputElement $ def
        & initialAttributes <>~ ("disabled" =: "true" <> "class" =: "account-details__kadena-address labeled-input__input")
        & inputElementConfig_initialValue .~ address
      void $ copyButton (def
        & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
        & uiButtonCfg_title .~ constDyn (Just "Copy")
        ) $ pure address
      pure ()

uiReceiveFromLegacyAccount
  :: ( MonadWidget t m
     , HasWallet model key t
     , HasNetwork model t
     , HasCrypto key (Performable m)
     )
  => model
  -> m (Dynamic t (Maybe (LegacyTransferInfo key)))
uiReceiveFromLegacyAccount model = do
  mAccountName <- uiAccountNameInput (model ^. wallet)

  onKeyPair <- divClass "account-details__private-key" $
    _inputElement_input <$> mkLabeledInput True "Private Key" uiInputElement def

  (deriveErr, okPair) <- fmap fanEither . performEvent $ deriveKeyPair <$> onKeyPair

  _ <- widgetHold blank $ leftmost
    [ text <$> deriveErr
    , blank <$ okPair
    ]

  keyPair <- holdDyn Nothing $ Just <$> okPair

  chain <- divClass "account-details__receive-from-chain" $ userChainIdSelect model

  amount <- fst . snd <$> mkLabeledInput True "Amount"
    (uiRealWithPrecisionInputElement maxCoinPrecision id) def

  pure $ (\macc mc mamnt mkeypair -> LegacyTransferInfo <$> macc <*> mc <*> mamnt <*> mkeypair)
    <$> mAccountName
    <*> chain
    <*> amount
    <*> keyPair

  where
    deriveKeyPair :: (HasCrypto key m, MonadJSM m) => Text -> m (Either Text (key, PublicKey))
    deriveKeyPair inp = cryptoGenPubKeyFromPrivate PactScheme.ED25519 inp
      >>= traverse (cryptoGenKey . GenFromPactKey) . first T.pack

uiReceiveModal
  :: ( MonadWidget t m
     , Monoid mConf
     , HasNetwork model t
     , HasNetworkCfg mConf t
     , HasWallet model key t
     , Flattenable mConf t
     , HasCrypto key m
     , HasCrypto key (Performable m)
     )
  => model
  -> Account key
  -> Event t ()
  -> m (mConf, Event t ())
uiReceiveModal model account _onClose = do
  onClose <- modalHeader $ text "Receive"
  (conf, closes) <- fmap splitDynPure $ workflow $ uiReceiveModal0 model account onClose
  mConf <- flatten =<< tagOnPostBuild conf
  let close = switch $ current closes
  pure (mConf, close)

uiReceiveModal0
  :: ( MonadWidget t m
     , Monoid mConf
     , HasNetwork model t
     , HasNetworkCfg mConf t
     , HasWallet model key t
     , HasCrypto key (Performable m)
     , HasCrypto key m
     )
  => model
  -> Account key
  -> Event t ()
  -> Workflow t m (mConf, Event t ())
uiReceiveModal0 model account onClose = Workflow $ do
  let
    chain = _account_chainId account

    netInfo = do
      nodes <- model ^. network_selectedNodes
      meta <- model ^. network_meta
      let networkId = hush . mkNetworkName . nodeVersion <=< headMay $ rights nodes
      pure $ (nodes, meta, ) <$> networkId

    address = textKadenaAddress $ accountToKadenaAddress account

    displayText lbl v cls =
      let
        attrFn cfg = uiInputElement $ cfg
          & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
      in
        mkLabeledInputView True lbl attrFn $ pure v

  (showingAddr, (conf, ttl, gaslimit, transferInfo)) <- divClass "modal__main account-details" $ do
    rec
      showingKadenaAddress <- holdDyn True $
        not <$> current showingKadenaAddress <@ onAddrClick <> onReceiClick

      (onAddrClick, _) <- controlledAccordionItem showingKadenaAddress mempty (text "Via address")
        $ do
        elClass "h2" "heading heading_type_h2" $ text "Destination"
        divClass "group" $ do
          -- Network
          void $ mkLabeledClsInput True "Network" $ \_ -> do
            stat <- queryNetworkStatus (model ^. network_networks) $ pure $ _account_network account
            uiNetworkStatus "signal__left-floated" stat
            text $ textNetworkName $ _account_network account
          -- Chain id
          _ <- displayText "Chain ID" (_chainId $ _account_chainId account) "account-details__chain-id"
          pure ()
        uiDisplayAddress address

      (onReceiClick, results) <- controlledAccordionItem (not <$> showingKadenaAddress) mempty
        (text "Via legacy (non-BIP32) sender") $ do
        elClass "h2" "heading heading_type_h2" $ text "Sender Details"
        transferInfo0 <- divClass "group" $ uiReceiveFromLegacyAccount model
        elClass "h2" "heading heading_type_h2" $ text "Transaction Settings"
        (conf0, ttl0, gaslimit0) <- divClass "group" $ uiMetaData model Nothing Nothing
        pure (conf0, ttl0, gaslimit0, transferInfo0)

    pure (showingKadenaAddress, snd results)

  let isDisabled = liftA2 (&&) (isNothing <$> transferInfo) (not <$> showingAddr)

  doneNext <- modalFooter $ uiButtonDyn
    (def
     & uiButtonCfg_class <>~ "button_type_confirm"
     & uiButtonCfg_disabled .~ isDisabled
    )
    $ dynText (bool "Submit Transfer" "Close" <$> showingAddr)

  let
    done = gate (current showingAddr) doneNext
    deploy = gate (not <$> current showingAddr) doneNext

    infos = (liftA2 . liftA2) (,) netInfo transferInfo

  pure ( (conf, onClose <> done)
       , uncurry
         <$> current (receiveFromLegacySubmit account chain <$> ttl <*> gaslimit)
         <@> tagMaybe (current infos) deploy
       )

receiveFromLegacySubmit
  :: ( Monoid mConf
     , CanSubmitTransaction t m
     , HasCrypto key m
     )
  => Account key
  -> ChainId
  -> TTLSeconds
  -> GasLimit
  -> ([Either a NodeInfo], PublicMeta, NetworkName)
  -> LegacyTransferInfo key
  -> Workflow t m (mConf, Event t ())
receiveFromLegacySubmit account chainId ttl gasLimit netInfo transferInfo = Workflow $ do
  recInfo <- receiveBuildCommand account netInfo ttl gasLimit transferInfo
  txnSubFeedback <- elClass "div" "modal__main transaction_details" $
    submitTransactionWithFeedback (_receiveBuildCommandInfo_command recInfo) chainId (netInfo ^. _1)

  let isDisabled = maybe True isLeft <$> _transactionSubmitFeedback_message txnSubFeedback

  done <- modalFooter $ uiButtonDyn
    (def & uiButtonCfg_class .~ "button_type_confirm" & uiButtonCfg_disabled .~ isDisabled)
    (text "Done")

  pure
    ( (mempty, done)
    , never
    )

receiveBuildCommand
  :: forall m key a.
     ( MonadJSM m
     , HasCrypto key m
     )
  => Account key
  -> ([Either a NodeInfo], PublicMeta, NetworkName)
  -> TTLSeconds
  -> GasLimit
  -> LegacyTransferInfo key
  -> m (ReceiveBuildCommandInfo key)
receiveBuildCommand account (_, publicMeta, networkId) ttl gasLimit transferInfo = do
  let
    chain = _legacyTransferInfo_chainId transferInfo
    sender = _legacyTransferInfo_account transferInfo
    senderPubKey = snd $ _legacyTransferInfo_keyPair transferInfo
    senderKey = fst $ _legacyTransferInfo_keyPair transferInfo
    amount = _legacyTransferInfo_amount transferInfo

    code = T.unwords $
      [ "(coin." <> accountCreatedYesNo account "transfer" "transfer-create"
      , tshow $ unAccountName $ sender
      , tshow $ unAccountName $ _account_name account
      , accountCreatedYesNo account mempty "(read-keyset 'key)"
      , tshow amount
      , ")"
      ]

    transferSigCap = SigCapability
      { _scName = QualifiedName
        { _qnQual = "coin"
        , _qnName = "TRANSFER"
        , _qnInfo = def
        }
      , _scArgs =
        [ PLiteral $ LString $ unAccountName sender
        , PLiteral $ LString $ unAccountName $ _account_name account
        , PLiteral $ LDecimal amount
        ]
      }

    transferCapability = DappCap
      { _dappCap_role = "TRANFER"
      , _dappCap_description = T.empty
      , _dappCap_cap = transferSigCap
      }

    dat = case accountIsCreated account of
      AccountCreated_No
        | Right pk <- parsePublicKey (unAccountName $ _account_name account)
        -> HM.singleton "key" $ Aeson.toJSON $ KeySet [toPactPublicKey pk] (Name $ BareName "keys-all" def)
      _ -> mempty

    signingPairs = [KeyPair senderPubKey (Just senderKey)]

    caps = [transferCapability, defaultGASCapability]

    pkCaps = Map.singleton senderPubKey [_dappCap_cap defaultGASCapability, transferSigCap]

    pm = publicMeta
      { _pmChainId = chain
      , _pmSender = unAccountName $ _account_name account
      , _pmGasLimit = gasLimit
      , _pmTTL = ttl
      }

  cmd <- buildCmd Nothing networkId pm signingPairs [] code dat pkCaps
  pure $ ReceiveBuildCommandInfo code transferInfo cmd signingPairs pm caps pkCaps dat
