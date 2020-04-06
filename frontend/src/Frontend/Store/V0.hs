{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
module Frontend.Store.V0 ( StoreFrontend(StoreNetwork_Networks, StoreWallet_Keys)) where

import Data.Aeson
import Data.Aeson.GADT.TH
import Data.Constraint (Dict(Dict))
import Data.Constraint.Extras
import Data.Map (Map)
import Data.Text (Text)

import Frontend.Store.TH
import Frontend.Store.V0.Wallet

-- WARNING: Be careful about changing stuff in here. Tests will catch snafus here and upstream though
import Common.Network (NetworkName)
import Common.OAuth (OAuthProvider)
import Common.GistStore (GistMeta)

-- WARNING: Upstream deps. Check this when we bump pact and obelisk!
-- May be worth storing this in upstream independent datatypes.
import Pact.Types.ChainMeta (PublicMeta (..))
import Obelisk.OAuth.Common (AccessToken, OAuthState)

data StoreFrontend key a where
  StoreWallet_Keys :: StoreFrontend key (Accounts key)

  StoreNetwork_Networks :: StoreFrontend key NetworkMap

deriving instance Show (StoreFrontend key a)

-- The TH doesn't deal with the key type param well because the key in each constructor is actually a
-- different type variable to the one in the data decl.
--
-- src/Frontend/Store/V0.hs:69:1-29: error:
--    The exact Name ‘key_a2Kfr’ is not in scope
--      Probable cause: you used a unique Template Haskell name (NameU),
--      perhaps via newName, but did not bind it
--      If that's it, then -ddump-splices might be useful

instance ArgDict c (StoreFrontend key) where
  type ConstraintsFor (StoreFrontend key) c
    = ( c (Accounts key)
      , c PublicMeta
      , c NetworkMap
      , c NetworkName
      , c (Map OAuthProvider AccessToken)
      , c OAuthState
      , c (GistMeta, Text)
      , c Text
      )
  argDict = \case
    StoreWallet_Keys {} -> Dict
    StoreNetwork_Networks {} -> Dict

deriveStoreInstances ''StoreFrontend
deriveJSONGADT ''StoreFrontend
