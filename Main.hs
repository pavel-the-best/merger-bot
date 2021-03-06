{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}

module Main where


import           Data.HashMap.Strict              (HashMap)
import qualified Data.HashMap.Strict              as HashMap
import           Data.Maybe
import           Data.Text                        (Text)
import qualified Data.Text                        as Text
import           Text.Read
import           Control.Monad.STM
import           Control.Monad.IO.Class
import           Control.Concurrent.STM.TVar
import           GHC.Generics
import           System.Envy

import           Telegram.Bot.API
import           Telegram.Bot.Simple
import           Telegram.Bot.Simple.UpdateParser (updateMessageText)

type MyMap = HashMap (ChatId, MessageId) MessageId
data Model = Model { messageIds :: TVar MyMap, mergeChatId :: ChatId, allowedChats :: [ChatId]}

data Action
  = NoOp
  | Fwd Message
  | Edit Message

data BotConfig = BotConfig {
    botToken :: Token -- "BOT_TOKEN"
  , botMergeChatId :: ChatId -- "BOT_MERGE_CHAT_ID"
  , botAllowedChats :: [ChatId] -- "BOT_ALLOWED_CHAT_IDS"
} deriving (Generic, Show)

instance Var Token where
  fromVar x = Just $ Token $ Text.pack x
instance Var ChatId where
  fromVar x = ChatId <$> readMaybe x
instance Var [ChatId] where
  fromVar x = map ChatId <$> readMaybe x
instance FromEnv BotConfig

echoBot :: ChatId -> [ChatId] -> TVar MyMap -> BotApp Model Action
echoBot mergechatid allowedchats map = BotApp
  { botInitialModel = Model { messageIds = map, mergeChatId = mergechatid, allowedChats = allowedchats }
  , botAction = updateToAction
  , botHandler = handleAction
  , botJobs = []
  }

goodChatId :: Model -> ChatId -> Bool
goodChatId model chatId = elem chatId $ allowedChats model

goodUpdate :: Model -> Maybe Message -> Bool
goodUpdate model x = isJust x && goodChatId model (chatId $ messageChat $ fromJust x)

updateToAction :: Update -> Model -> Maybe Action
updateToAction update model
  | goodUpdate model $ updateChannelPost update = Just $ Fwd (fromJust $ updateChannelPost update)
  | goodUpdate model $ updateEditedChannelPost update = Just $ Edit (fromJust $ updateEditedChannelPost update)
  | otherwise = Nothing

handleAction :: Action -> Model -> Eff Action Model
handleAction action model = case action of
  NoOp -> pure model
  Fwd msg -> model <# do
    let fromChatId = chatId $ messageChat msg
    res <- liftClientM $ forwardMessage $ ForwardMessageRequest {
                                            forwardMessageChatId = SomeChatId (mergeChatId model)
                                           ,forwardMessageFromChatId = SomeChatId $ chatId $ messageChat msg
                                           ,forwardMessageDisableNotification = Nothing
                                           ,forwardMessageMessageId = messageMessageId msg }
    if responseOk res then
        liftIO $ atomically $ modifyTVar' (messageIds model) (HashMap.insert (fromChatId, messageMessageId msg) (messageMessageId $ responseResult res))
    else
        undefined
    return NoOp
  Edit msg -> model <# do
    ids <- liftIO $ readTVarIO (messageIds model)
    let toEdit = HashMap.lookup (chatId $ messageChat msg, messageMessageId msg) ids
    case toEdit of
        Just id -> do
          liftClientM $ deleteMessage (mergeChatId model) id
          return $ Fwd msg
        Nothing -> do
          liftClientM $ liftIO $ putStrLn "Unknown message was edited"
          return NoOp

run :: BotConfig -> IO ()
run config = do
  env <- defaultTelegramClientEnv (botToken config)
  res <- newTVarIO HashMap.empty
  startBot_ (conversationBot updateChatId $ echoBot (botMergeChatId config) (botAllowedChats config) res) env

main :: IO ()
main = do
        config <- decodeEnv :: IO (Either String BotConfig)
        case config of
            Right conf -> run conf
            Left err -> error err
