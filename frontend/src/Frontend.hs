{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
module Frontend where

import           Control.Monad            (void)
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Reflex.Dom.Core
import Pact.Server.ApiV1Client (runTransactionLoggerT, logTransactionStdout)

import           Obelisk.Frontend
import           Obelisk.Route.Frontend
import           Obelisk.Generated.Static

import           Common.Api
import           Common.Route
import           Frontend.Crypto.Browser
import           Frontend.ReplGhcjs
import           Frontend.Storage

frontend :: Frontend (R FrontendRoute)
frontend = Frontend
  { _frontend_head = do
      let backendEncoder = either (error "frontend: Failed to check backendRouteEncoder") id $
            checkEncoder backendRouteEncoder
      -- Global site tag (gtag.js) - Google Analytics
      gaTrackingId <- maybe "UA-127512784-1" T.strip <$> getTextCfg "frontend/tracking-id"
      let
        gtagSrc = "https://www.googletagmanager.com/gtag/js?id=" <> gaTrackingId
      elAttr "script" ("async" =: "" <> "src" =: gtagSrc) blank
      el "script" $ text $ T.unlines
        [ "window.dataLayer = window.dataLayer || [];"
        , "function gtag(){dataLayer.push(arguments);}"
        , "gtag('js', new Date());"
        , "gtag('config', '" <> gaTrackingId <> "');"
        ]

      base <- getConfigRoute
      _ <- newHead $ \r -> base <> renderBackendRoute backendEncoder r
      pure ()

  , _frontend_body = prerender_ loaderMarkup $ do
    mapRoutedT (flip runTransactionLoggerT logTransactionStdout . runBrowserStorageT . runBrowserCryptoT) app
  }

tshow :: Show a => a -> Text
tshow = T.pack . show

loaderMarkup :: DomBuilder t m => m ()
loaderMarkup = divClass "spinner" $ do
  divClass "spinner__cubes" $ do
    divClass "cube1" blank
    divClass "cube2" blank
  divClass "spinner__msg" $ text "Loading"

newHead :: (Prerender js t m, DomBuilder t m) => (R BackendRoute -> Text) -> m (Event t ())
newHead routeText = do
  el "title" $ text "Kadena - Pact Testnet"
  elAttr "link" ("rel" =: "icon" <> "type" =: "image/png" <> "href" =: static @"img/favicon/favicon-96x96.png") blank
  meta ("name" =: "description" <> "content" =: "Write, test, and deploy safe smart contracts using Pact, Kadena's programming language")
  meta ("name" =: "keywords" <> "content" =: "kadena, pact, pact testnet, pact language, pact programming language, smart contracts, safe smart contracts, smart contract language, blockchain, learn blockchain programming, chainweb")
  meta ("charset" =: "utf-8")
  meta ("name" =: "google" <> "content" =: "notranslate")
  meta ("http-equiv" =: "Content-Language" <> "content" =: "en_US")
  elAttr "link" ("href" =: routeText (BackendRoute_Css :/ ()) <> "rel" =: "stylesheet") blank
  elAttr "style" ("type" =: "text/css") $ text haskellCss

  ss "https://fonts.googleapis.com/css?family=Roboto"
  ss "https://fonts.googleapis.com/css?family=Work+Sans"
  ss (static @"css/font-awesome.min.css")
  ss (static @"css/ace-theme-chainweaver.css")
  js "/static/js/ace/ace.js"
  prerender_ blank $ js "/static/js/ace/mode-pact.js"
  js (static @"js/nacl-fast.min-v1.0.0.js")
  (bowser, _) <- js' (static @"js/bowser.min.js")
  pure $ domEvent Load bowser
  where
    js :: forall t n. DomBuilder t n => Text -> n ()
    js = void . js'
    js' :: forall t n. DomBuilder t n => Text -> n (Element EventResult (DomBuilderSpace n) t, ())
    js' url = elAttr' "script" ("type" =: "text/javascript" <> "src" =: url <> "charset" =: "utf-8") blank
    ss url = elAttr "link" ("href" =: url <> "rel" =: "stylesheet") blank
    meta attrs = elAttr "meta" attrs blank

    -- Allows the use of `static` in CSS and sharing parameters with desktop apps
    haskellCss = T.unlines
      [ "body { min-width: " <> tshow w <> "px; " <> "min-height: " <> tshow h <> "px; }"
      , alertImg ".icon_type_error"                $ static @"img/error.svg"
      , alertImg ".icon_type_warning"              $ static @"img/warning.svg"
      , alertImg "div.ace_gutter-cell.ace_error"   $ static @"img/error.svg"
      , alertImg "div.ace_gutter-cell.ace_warning" $ static @"img/warning.svg"
      ]
      where
        bgImg src = "background-image: url(" <> src <> "); background-position: left center"
        alertImg sel src = sel <> " { " <> bgImg src <> " } ";
        (w,h) = minWindowSize

minWindowSize :: (Int, Int)
minWindowSize = (800, 600)

defaultWindowSize :: (Int, Int)
defaultWindowSize = (1400, 900)
