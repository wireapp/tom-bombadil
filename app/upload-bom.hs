{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wall #-}

import Data.Aeson
import Data.ByteString.Base64.Lazy qualified as Base64
import Data.ByteString.Lazy as BL
import Data.Proxy
import Data.Text.Lazy
import Data.Text.Lazy.Encoding
import GHC.Generics
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Options.Applicative
import Servant.API
import Servant.Client
import System.Environment (lookupEnv)
import System.Exit
import System.Process

data Payload = Payload
  { bom :: Text,
    projectName :: String,
    projectVersion :: String,
    autoCreate :: Bool
  }
  deriving (Generic, Show)

instance ToJSON Payload

data ApiResponse = ApiResponse
  { token :: String
  }
  deriving (Generic, Show)

instance FromJSON ApiResponse

type DependenyTrackAPI =
  "api"
    :> "v1"
    :> "bom"
    :> ReqBody '[JSON] Payload
    :> Header "X-Api-Key" String
    :> Put '[JSON] ApiResponse

api :: Proxy DependenyTrackAPI
api = Proxy

putBOM :: Payload -> Maybe String -> ClientM ApiResponse
putBOM = client api

data CliOptions = CliOptions
  { opProjectName :: String,
    opProjectVersion :: String,
    opAutoCreate :: Bool,
    opApiKey :: String,
    opBomFilename :: FilePath
  }
  deriving (Show)

cliParser :: Maybe String -> Parser CliOptions
cliParser mbApiKey =
  CliOptions
    <$> strOption
      ( long "project-name"
          <> short 'p'
          <> metavar "PROJECT_NAME"
          <> value "wire-server-ci"
      )
    <*> strOption
      ( long "project-version"
          <> short 'v'
          <> metavar "PROJECT_VERSION"
      )
    <*> switch
      ( long "auto-create"
          <> short 'c'
      )
    <*> apiKeyOption
    <*> strOption
      ( long "bom-file"
          <> short 'f'
          <> metavar "BOM_FILENAME"
          <> value "sbom.json"
      )
  where
    apiKeyOption :: Parser String
    apiKeyOption = case mbApiKey of
      Nothing ->
        strOption
          ( long "api-key"
              <> short 'k'
              <> metavar "API_KEY"
              <> help "Either --api-key option or env variable DEPENDENCY_TRACK_API_KEY required"
          )
      Just apiKey ->
        strOption
          ( long "api-key"
              <> short 'k'
              <> metavar "API_KEY"
              <> value apiKey
          )

fullCliParser :: Maybe String -> ParserInfo CliOptions
fullCliParser mbApiKey =
  info
    (cliParser mbApiKey <**> helper)
    ( fullDesc
        <> progDesc "Upload BOM files to deptrack"
    )

main :: IO ()
main = do
  mbApiKey <- lookupEnv "DEPENDENCY_TRACK_API_KEY"
  options <- execParser $ fullCliParser mbApiKey
  manager' <- HTTP.newManager tlsManagerSettings

  bom <- BL.readFile (opBomFilename options)
  let payload =
        Payload
          { bom = toBase64Text bom,
            projectName = opProjectName options,
            projectVersion = opProjectVersion options,
            autoCreate = opAutoCreate options
          }
  res <-
    runClientM
      (putBOM payload ((Just . opApiKey) options))
      (mkClientEnv manager' (BaseUrl Https "deptrack.wire.link" 443 ""))
  case res of
    Left err -> print $ "Error: " ++ show err
    Right res' -> print res'

toBase64Text :: LazyByteString -> Text
toBase64Text = decodeUtf8 . Base64.encode
