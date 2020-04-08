{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE QuasiQuotes #-}

module Frontend where

import Reflex.Dom.Core ( prerender_, blank, MonadWidget )
import Obelisk.Frontend ( Frontend(..) )
import Obelisk.Route.Frontend ( RoutedT )
import Common.Route ( FrontendRoute )
import Language.Javascript.JSaddle ( liftJSM )
import Obelisk.Route ( R )
import qualified Servant.API as S
import qualified Servant.Client.JSaddle as S
import qualified Data.Aeson as Aeson ( ToJSON, encode )
import qualified Data.ByteString.Lazy as BL ( toStrict )
import qualified Data.Dependent.Map as DMap ( DMap, empty )
import Data.Dependent.Sum.Orphans ()
import Data.Functor.Identity ( Identity )
import Data.Text ( Text )
import qualified Data.Text.Encoding as T ( decodeUtf8 )
import qualified Frontend.Store.V0 as V0 ( StoreFrontend )
import Data.Proxy

encodeText :: Aeson.ToJSON a => a -> Text
encodeText = T.decodeUtf8 . BL.toStrict . Aeson.encode

type TrivialApi = S.Get '[S.JSON] ()

trivialClient :: S.ClientM ()
trivialClient = S.client $ Proxy @TrivialApi

app :: forall t m.
     ( MonadWidget t m
     )
  => RoutedT t (R FrontendRoute) m ()
app = do
  encodeText (DMap.empty :: DMap.DMap V0.StoreFrontend Identity) `seq` pure ()

  let env = S.mkClientEnv $ S.BaseUrl S.Https "eu1.testnet.chainweb.com" 80 "/chainweb/0.0/testnet04/chain/8/pact"

  _ <- liftJSM $ S.runClientM trivialClient env

  pure ()

frontend :: Frontend (R FrontendRoute)
frontend = Frontend
  { _frontend_head = blank
  , _frontend_body = prerender_ blank app
  }
