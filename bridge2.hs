import System.IO.Unsafe
import Network
import Network.HTTP
import System.IO
import Control.Exception
import Control.Concurrent
import Data.List 
import Data.Char (toUpper)
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Time.LocalTime
import Data.Time.Format
import System.Locale
import qualified Data.String.Utils as S
import qualified Data.Set as Set
import Control.Monad
import Control.Concurrent
import Control.Concurrent.Chan
import Text.Regex

type AddonUserName = String
type IRCUserName = String

data AwayState = Here | Away
                 deriving (Show, Ord, Eq)

data User = User {addonUserName :: AddonUserName,
                  ircUserName :: IRCUserName,
                  userAwayState :: AwayState,
                  userColor :: UserColor
                 }
            deriving (Show, Ord, Eq)

data UserColor = Unknown | Blue | Red | Gold | Green | White
                 deriving (Show, Ord, Eq)

data Room = Room {roomName :: String,
                  permanent :: Bool,
                  todayCloseTime :: Int,
                  todayReopenTime :: Int,
                  userList :: [User]
                 }
            deriving (Ord, Eq)
                  
            
data BridgeMessage = AddonPingTime |
                     ConnectToAddon String Int |
                     EchoLine Line | 
                     GetRoomNames String String|
                     AddonAuth String String Int String String Int|
                     RoomNames [String] | 
                     AddonHandle Handle | 
                     StartAddonPing | 
                     DoPing |
                     RoomRejoiner String Int |
                     RejoinRoom String
                     deriving (Show, Eq)

data Line = BridgeLine BridgeMessage | 
            IRCLine String | 
            AddonLine {af0 :: Int,
                       af1 :: Int,
                       af2 :: Int,
                       af3 :: String,
                       af4 :: String,
                       af5 :: String,
                       af6 :: Int,
                       af7 :: Int,
                       af8 :: Int
                      }
          deriving (Eq)

instance Show Line where
    show (BridgeLine message) = show message
    show (IRCLine s) = s
    show (AddonLine f0 f1 f2 f3 f4 f5 f6 f7 f8) = (show f0) ++ "\t" ++ 
                                                  (show f1) ++ "\t" ++ 
                                                  (show f2) ++ "\t" ++
                                                  f3 ++ "\t" ++
                                                  f4 ++ "\t" ++
                                                  f5 ++ "\t" ++
                                                  (show f6) ++ "\t" ++
                                                  (show f7) ++ "\t" ++
                                                  (show f8)


data BState = BState {myNick :: String,
                      myPassword :: String,

                      server :: String,
                      addonPort :: Int,
                      channelName :: String,
                      accountID :: String,
                      defaultRoomName :: String,

                      timeZone :: TimeZone,

                      roomList :: [Room],
                      usersInNoRoom :: [User],

                      --inPipe :: Chan Line,
                      roomMove :: String
                     }

main :: IO ()
main = do
  inputPipe <- newChan
  ircOutPipe <- newChan
  addonOutPipe <- newChan
  curTime <- getCurrentTime
  state <- initialBState inputPipe
  bracket (listenOn $ PortNumber 10200) 
              (sClose) 
              (acceptS state inputPipe ircOutPipe addonOutPipe)
      where
        acceptS state inputPipe ircOutPipe addonOutPipe sock = 
            accept sock >>= handle state inputPipe ircOutPipe addonOutPipe
        handle state inputPipe ircOutPipe addonOutPipe (h, n, p) = do
          let s = state --{ircHandle = h}
          hSetBuffering h LineBuffering
          forkIO (ircListener inputPipe h)
          forkIO (ircSender ircOutPipe h)
          inList <- getChanContents inputPipe
          putStrLn "testicle"
          sequence_ $ map (writeLine inputPipe ircOutPipe addonOutPipe) 
                        (transformInput s inList)

-- This is the main function, takes a list of Line and turns it into a list of 
-- IO actions
transformInput :: BState -> [Line] -> [Line]
transformInput state lines = join (snd $ mapAccumL processLine state lines) 

-- write a line to where it goes
writeLine :: Chan Line -> Chan Line -> Chan Line -> Line -> IO ()
writeLine inputPipe ircOutPipe addonOutPipe line@(IRCLine l) = do
  writeChan ircOutPipe line

writeLine inputPipe ircOutPipe addonOutPipe l@(AddonLine _ _ _ _ _ _ _ _ _) = do
  writeChan addonOutPipe l

writeLine inputPipe ircOutPipe addonOutPipe 
              (BridgeLine (ConnectToAddon aServer aPort)) = do
  h <- connectTo aServer (PortNumber $ fromIntegral (aPort))
  hSetBuffering h LineBuffering
  forkIO (addonListener inputPipe h)
  forkIO (addonSender addonOutPipe h)
  --writeChan pipe $ BridgeLine (AddonHandle h)
  return ()

writeLine inputPipe ircOutPipe addonOutPipe (BridgeLine (EchoLine line)) = 
    writeChan inputPipe line

writeLine inputPipe ircOutPipe addonOutPipe 
              (BridgeLine (GetRoomNames aServer aAccountID)) = do
  page <- httpRequest url
  let strL = prse page
  writeChan inputPipe $ BridgeLine (RoomNames strL)
      where
        prse page = map (drop 2 . dropWhile (/= '=')) 
                        (filter ("subroom" `isPrefixOf`) (lines page))
        url = "http://" ++ aServer ++ "/current/data/settings.php?aid=" ++ 
              aAccountID

writeLine inputPipe ircOutPipe addonOutPipe 
              (BridgeLine (AddonAuth aServer aAccountID aPort aNick aPassword sfd)) = 
    httpRequest url >>= putStrLn
    where
      url = "http://" ++ aServer ++ 
            "/current/data/rauth.php?aid=" ++ aAccountID 
            ++ "&port=" ++ (show (aPort))
            ++ "&un=" ++ aNick
            ++ "&upw=" ++ aPassword
            ++ "&sfd=" ++ (show sfd)
            ++ "&rndname=-1"

writeLine inputPipe ircOutPipe addonOutPipe (BridgeLine StartAddonPing) = 
    forkIO (addonPingTimer inputPipe) >> return ()

writeLine inputPipe ircOutPipe addonOutPipe 
              (BridgeLine (RoomRejoiner rName totalTimeClosed)) = 
                  forkIO (roomRejoiner inputPipe rName totalTimeClosed) >> 
                  return ()


-- Make the initial BState, mostly filled with dumb values. Could read in
-- some of the defaults from a file in the future.
initialBState :: Chan Line -> IO BState
initialBState pipe = do
  tz <- getCurrentTimeZone
  return BState {myNick = "",
                 myPassword = "",
                 server = "client11.addonchat.com",
                 addonPort = 8009,
                 channelName = "#carm",
                 accountID = "314349",
                 defaultRoomName = "The Skeptic Tank",
                 timeZone = tz,
                 roomList = [],
                 usersInNoRoom = [],
                 roomMove = ""
                }

{-Make HTTP connection for authentication and room list-}
httpRequest :: String -> IO String
httpRequest url = simpleHTTP (getRequest url) >>= getResponseBody


-- listen to ircOutPipe and send.
ircSender :: Chan Line -> Handle -> IO ()
ircSender ircOutPipe ircHandle = do
  output <- getChanContents ircOutPipe
  sequence_ $ map fun output
      where
        fun line = do
          let s = show line
          putStrLn $ "irc<<" ++ s
          hPutStrLn ircHandle s

-- listen to addonOutPipe and send.
addonSender :: Chan Line -> Handle -> IO ()
addonSender addonOutPipe addonHandle = do
  output <- getChanContents addonOutPipe
  sequence_ $ map fun output
      where
        fun line = do
          let s = show line
          putStrLn $ "add<<" ++ s
          hPutStrLn addonHandle s

-- listen for IRC traffic and pump down the pipe
ircListener :: Chan Line -> Handle -> IO ()
ircListener pipe h = do
  lines <- liftM ((map IRCLine) . fLines . lines) (hGetContents h)
  sequence_ $ map (fun) lines
    where
      fun line = do
        putStrLn $ "irc>>" ++ (show line)
        writeChan pipe line
      fLines [] = []
      fLines (l : ls) 
          | stripL == "" = fLines ls
          | otherwise = stripL : (fLines ls)
          where
            stripL = S.strip l

  --line <- hGetLine h
  --let l2 = S.strip line
  --if l2 == "" then return () else do
  --                             putStrLn $ "irc>>" ++ l2
  --                             writeChan pipe (IRCLine l2)
  --ircListener pipe h

-- listen for addon traffic and dump down pipe
addonListener :: Chan Line -> Handle -> IO()
addonListener pipe h = do
  line <- hGetLine h
  let l2 = S.strip line
  putStrLn $ "add>>" ++ l2
  writeChan pipe (stringToAddonLine l2)
  addonListener pipe h


roomRejoiner :: Chan Line -> String -> Int -> IO ()
roomRejoiner pipe rName totalTimeClosed = do
  print "****** Starting roomRejoiner ******"
  --curTime <- getPOSIXTime
  --print $ "****** Current Time: " ++ 
  --          (prettyTime tz (fromIntegral $ floor curTime)) ++ " ******"
  --print $ "****** Reopen Time: " ++ (prettyTime tz reopenTime) ++ " ******"
  --let waitTime = (reopenTime - (fromIntegral (floor curTime)) + 300) * 1000000
  --print $ "****** Raw waitTime: " ++ (show waitTime) ++ " ******"
  --print $ "****** Time it will be when waitTime is up: " ++ (fun curTime waitTime) ++
  --      " ******"
  threadDelay $ (totalTimeClosed + 60) * 1000000
  writeChan pipe $ BridgeLine (RejoinRoom rName)
--      where
--        fun cT wT = prettyTime tz ((fromIntegral (floor cT)) + ((wT :: Int) `div` 1000000))

addonPingTimer :: Chan Line -> IO ()
addonPingTimer pipe = do
  threadDelay 300000000
  writeChan pipe $ BridgeLine DoPing
  addonPingTimer pipe


-- Create a list of IO actions to take based on the line
processLine :: BState -> Line -> (BState, [Line])
processLine state (BridgeLine (RoomNames l)) = (newState, [])
    where
      newState = state {roomList = map makeRoom l}
      makeRoom rName = Room rName True 0 0 []

processLine state (BridgeLine DoPing) = (state,
                                         [AddonLine 2 0 0 etx etx etx 0 0 0]
                                        )
processLine state (BridgeLine (RejoinRoom rName)) 
    | myCurrentRoom state == Nothing = (state, [AddonLine 73 0 0 etx rName etx 1 0 0])
    | otherwise = (state, [])

processLine state b@(IRCLine l)
    | command == "NICK" = ircNick state l
    | command == "PASS" = ircPass state l
    | command == "PING" = ircPing state l
    | command == "PRIVMSG" = ircPrivMsg state l
    | command == "NAMES" = ircNames state l
    | command == "MOVE" = ircMove state l
    | command == "WHO" = ircWho state l
    | command == "SIGNON" = ircSignon state l
    | command == "HOURS" = ircHours state l
    | otherwise = (state, [])
    where
      command = map toUpper (head $ (words l))

processLine state b@(AddonLine f0 f1 f2 f3 f4 f5 f6 f7 f8)
    | command == 10021 = addonSpeech state f3 f5
    | command == 10049 = addonAction state f3 f5
    | command == 10009 = addonUserExists state f3
    | command == 10008 = addonRoomExists state 
                           f3 f1 f2 -- fields 1 and 2 are the 
                           -- closing and opening times for the 
                           -- room for the day, I think
    | command == 10019 = addonInitRoomComp state f3 f5
    | command == 10027 = addonRoomEnter state f3 f5
    | command == 10022 = addonUserLogout state f3
    | command == 10011 = addonUserLogin state f3
    | command == 10055 = addonUserAway state f3 f1
    | command == 10057 = addonUserBanned state f3
    | command == 10056 = addonUserKicked state f3
    | command == 10081 = addonGhostVoice state f5
    | command == 10023 = addonLeavingRoom state f3 f5
    | command == 1337 = addonLeet state f1
    | command == 10041 = addonAuthDo state f2
    | command == 10006 = addonJoinInit state 
    | command == 10044 = addonPMMessage state f3 f5
    | command == 10075 = addonCloseKick state f3 f6 f7
    | command == 10013 = addonCloseRoom state f1 f3 -- it's a time
    | command == 10110 = addonUserColor state f3 f1
    | command == 10048 = addonPMClose state f3
--    | command == 10015" = addonRoomClosedMessage state ((fields line)!!3) --room name
--    | command == 10048" = addonPMClose 
    | otherwise = (state, [])
      where
        command = f0

addonPMClose :: BState -> AddonUserName -> (BState, [Line])
addonPMClose state aName = (state, [IRCLine $ ":PMMonitor NOTICE " ++
                                            (channelName state) ++
                                            " :User " ++ aName ++
                                            " has closed his PM window."])

addonUserColor :: BState -> AddonUserName -> Int -> (BState, [Line])
addonUserColor state aName colorInt = (newState, [])
    where
      newState = state {roomList = newRoomList}
      newRoomList = map newRoom (roomList state)
      newRoom room = room {userList = fun (userList room)}
      fun uL = map tfun uL
      color Nothing = Unknown
      color (Just o) = o
      c = lookup colorInt colorsList
      tfun user 
          | (addonUserName user) == aName = user {userColor = (color c)}
          | otherwise = user


colorsList :: [(Int, UserColor)]
colorsList = [(3, Gold), (0, Blue), (2, Red), (1, Green), (4, White)]

addonCloseRoom :: BState -> Int -> String -> (BState, [Line])
addonCloseRoom state number rName 
    | curRoom == Nothing = (newState, [])
    | rName == (roomName r) = (newState, (lineFun rName) ++ [IRCLine $ ":Mover NOTICE " ++
                                          (channelName state) ++ 
                                          " :Now leaving " ++ rName]
                              )
    | otherwise = (newState, [])
    where
      lineFun rName = map fun userNames
          where
            fun iName = IRCLine $ ":" ++ iName ++ " PART " ++ (channelName state) ++ " :Leaving!"
            Just rm = getRoom state rName
            userNames = filter (\x -> myNick state /= x) $ 
                        map ircUserName (userList rm)
      curRoom = myCurrentRoom state
      Just r = curRoom
      newState = state {roomList = newRoomList, usersInNoRoom = newUINR}
      newRoomList 
          | isRoomPermanent state rName = map fun (roomList state)
          | otherwise = delete rm (roomList state)
          where
            Just rm = getRoom state rName
      fun room 
          | (roomName room) == rName = room {userList = []}
          | otherwise = room
      newUINR = (usersInNoRoom state) ++ (cRL)
      cRL = userList (head $ filter (\x -> roomName x == rName) (roomList state))


addonCloseKick :: BState -> String -> Int -> Int -> (BState, [Line])
addonCloseKick state rName timeReopenTomorrow timeClosedTomorrow = 
    (newState,
     [IRCLine $ ":RoomCloser NOTICE " ++ (channelName state) ++
                " :" ++ rName ++ " has closed. Room is closed from " ++
                (prettyTime (timeZone state) todayClose) ++ " to " ++ 
                (prettyTime (timeZone state) todayReopen),
      BridgeLine (RoomRejoiner rName totalTimeClosed)]
    )
    where
      totalTimeClosed = todayReopen - todayClose
      room = head (filter (\x -> roomName x == rName) (roomList state))
      todayClose = (todayCloseTime room)
      todayReopen = (todayReopenTime room)
      newState = state {roomList = newRoomList}
      newRoomList = map fun (roomList state)
      fun r 
          | (roomName r) == rName = r {todayCloseTime = timeClosedTomorrow, 
                                       todayReopenTime = timeReopenTomorrow}
          | otherwise = r

addonPMMessage :: BState -> AddonUserName -> String -> (BState, [Line])
addonPMMessage state aName message
    | aName == (myNick state) = (state, [])
    | otherwise = (state,
                   [IRCLine $ ":" ++ (sanitizeName aName) ++ 
                              " PRIVMSG " ++ (myNick state) ++ " :" ++
                              (sanitizeAddonMessage state message)]
                  )

addonJoinInit :: BState -> (BState, [Line])
addonJoinInit state = (state,
                       [AddonLine 4 0 0 (defaultRoomName state) etx etx 0 0 0]
                      )

addonAuthDo :: BState -> Int -> (BState, [Line])
addonAuthDo state num = (state,
                         [BridgeLine (GetRoomNames (server state) (accountID state)),
                          BridgeLine (AddonAuth (server state)
                                                (accountID state)
                                                (addonPort state)
                                                (myNick state)
                                                (myPassword state)
                                                num),
                          BridgeLine (StartAddonPing)]
                        )


addonLeet :: BState -> Int -> (BState, [Line])
addonLeet state magicNum = (state, 
                            [AddonLine 1337 outNum 0
                                       etx etx etx 0 0 0,
                             AddonLine 11 0 (read (accountID state))
                                       etx etx etx 0 0 0]
                           )
    where
      outNum = (magicNum `mod` 1337) * ((magicNum `div` 2) `mod` 27)

addonLeavingRoom :: BState -> AddonUserName -> String -> (BState, [Line])
addonLeavingRoom state aName rName 
    | aName == (myNick state) = (state {roomMove = ""},
                                 [IRCLine $ ":Mover NOTICE " ++
                                            (channelName state) ++
                                            " :Now leaving " ++ rName,
                                  AddonLine 4 20 0
                                            (roomMove state) etx etx 0 0 0]
                                )
    | otherwise = (state, [])

addonGhostVoice :: BState -> String -> (BState, [Line])
addonGhostVoice state message = (state,
                                 [IRCLine $ ":GhostedAdmin NOTICE " ++
                                            (channelName state) ++
                                            " :" ++ message]
                                )

addonUserKicked :: BState -> AddonUserName -> (BState, [Line])
addonUserKicked state aName = (newState,
                               (IRCLine $ ":Kicker NOTICE " ++
                                          (channelName state) ++
                                          " :" ++ (sanitizeName aName)) : newList
                              )
    where
      (newState, newList) = addonUserLogout state aName

addonUserBanned :: BState -> AddonUserName -> (BState, [Line])
addonUserBanned state aName = (newState, 
                               (IRCLine $ ":Banninator NOTICE " ++
                                          (channelName state) ++
                                          " :" ++ (sanitizeName aName)) : newList
                              )                                   
    where
      (newState, newList) = addonUserLogout state aName

addonUserAway :: BState -> AddonUserName -> Int -> (BState, [Line])
addonUserAway state aName awayState = (newState, [])
    where
      newState = state {roomList = newRoomList}
      newRoomList = map newRoom (roomList state)
      newRoom room = room {userList = fun (userList room)}
      fun uL = map tfun uL
      astate 
          | awayState == 0 = Here
          | otherwise = Away
      tfun user 
          | (addonUserName user) == aName = user {userAwayState = astate}
          | otherwise = user

addonUserLogin :: BState -> AddonUserName -> (BState, [Line])
addonUserLogin state aName = (newState, 
                              [IRCLine $ ":Login NOTICE " ++
                                                 (channelName state) ++
                                                 " :User " ++ 
                                                 (sanitizeName aName) ++
                                                 " has logged in."]
                             )
    where
      newState = state {usersInNoRoom = (createUser aName) : (usersInNoRoom state)}

addonUserLogout :: BState -> AddonUserName -> (BState, [Line])
addonUserLogout state aName 
    | curRoom == Nothing = (removedState, [rest])
    | curRoom == currentRoom state aName = (removedState,
                                            [IRCLine $ ":" ++
                                                       (sanitizeName aName) ++
                                                       " PART " ++
                                                       (channelName state) ++
                                                       " :Leaving!",
                                             rest]
                                           )
    | otherwise = (removedState, [rest])
    where
      curRoom = myCurrentRoom state
      (_, removedState) = removeUserFromRoom state aName
      rest = IRCLine $ ":Logout NOTICE " ++ (channelName state) ++
                                       " :User " ++ (sanitizeName aName) ++
                                       " has logged out."

addonRoomEnter :: BState -> AddonUserName -> String -> (BState, [Line])
addonRoomEnter state aName rName
    | curRoom == Nothing && 
        aName /= (myNick state) = (addUserToRoom removedState user rName, [])
    | aName == (myNick state) = (addUserToRoom removedState user rName, 
                                 [IRCLine $ ":Mover NOTICE " ++
                                            (channelName state) ++
                                            " :Now entering " ++
                                            rName,
                                  BridgeLine 
                                                (EchoLine 
                                                 (IRCLine $ "NAMES " ++ 
                                                  (channelName state)))]
                                )
    | currentRoom state aName == curRoom &&
      not (userInRoom state aName rName) = (addUserToRoom removedState user rName,
                                            [IRCLine $ ":" ++
                                             (sanitizeName aName) ++
                                             " PART " ++ 
                                             (channelName state) ++
                                             " :Leaving!"]
                                           )
    | userInRoom state (myNick state) rName = (addUserToRoom removedState user rName,
                                               [IRCLine $ ":" ++
                                                          (sanitizeName aName) ++ 
                                                          " JOIN :" ++
                                                          (channelName state)]
                                              )
    | otherwise = (addUserToRoom removedState user rName, [])
    where
      curRoom = myCurrentRoom state
      Just r = curRoom
      (user, removedState) = removeUserFromRoom state aName

addonInitRoomComp :: BState -> AddonUserName -> String -> (BState, [Line])
addonInitRoomComp state aName rName 
    | userExists state aName = (addUserToRoom newState u rName, [])
    | otherwise = (addUserToRoom state (createUser aName) rName, [])
    where
      (u, newState) = removeUserFromRoom state aName  

addonRoomExists :: BState -> String -> Int -> Int -> (BState, [Line])
addonRoomExists state rName tC tO  
    | inList rName = (state {roomList = map fun (roomList state)},
                      []
                     )
    | otherwise = (state {roomList = (Room rName False (tC) (tO) []) : (roomList state)}, [])
    where
      fun room
          | (roomName room) == rName = room {todayCloseTime = tC, todayReopenTime = tO}
          | otherwise = room
      rTime t = readTime defaultTimeLocale "%s" t
      inList rN = elem rN (map roomName (roomList state))

addonUserExists :: BState -> AddonUserName -> (BState, [Line])
addonUserExists state aName
    | userExists state aName = (state, [])
    | otherwise = (addUser state (createUser aName) "nowhere", [])

addUserToRoom :: BState -> User -> String -> BState
addUserToRoom state user rName = newRoomList user rName state
    where
      newRoomList u r s = s {roomList = map (newRoom u r) (roomList state)}
      newRoom u rName room 
          | (roomName room) == rName = room {userList = u : (userList room)}
          | otherwise = room

removeUserFromRoom :: BState -> AddonUserName -> (User, BState)
removeUserFromRoom state aName = (findUser aName state , newState aName state)
    where
      findUser n s = head $ filter (\x -> addonUserName x == n) (masterList s)
      masterList s = concat ((usersInNoRoom s) : (map (userList) (roomList s)))
      newUserList n l = filter (\x -> (addonUserName x) /= n) l
      newRoom n r = r {userList = (newUserList n $ userList r)}
      newRoomList n rs = map (newRoom n) rs
      newState n s = s {roomList = newRoomList n (roomList s),
                        usersInNoRoom = newUserList n (usersInNoRoom s)}

isRoomPermanent :: BState -> String -> Bool
isRoomPermanent state rName = maybe False permanent (getRoom state rName)

getRoom :: BState -> String -> Maybe Room
getRoom state rName
    | null rList = Nothing
    | otherwise = Just $ head rList
    where
      rList = filter (\x -> roomName x == rName) (roomList state)

userInRoom :: BState -> AddonUserName -> String -> Bool
userInRoom state aName rName 
    | curRoom == Nothing = False
    | otherwise = (roomName r) == rName
    where
      curRoom = currentRoom state aName
      Just r = curRoom

createUser :: AddonUserName -> User
createUser aName = User aName (sanitizeName aName) Here Unknown

userExists :: BState -> AddonUserName -> Bool
userExists state aName = (inRooms aName) || (inList aName (usersInNoRoom state))
    where
      inList aName list = any (\x -> (addonUserName x) == aName) list
      inRooms aName = any (inList aName) (map userList (roomList state))

addUser :: BState -> User -> String -> BState
addUser state user rName 
    | rName == "nowhere" = state {usersInNoRoom = (user : (usersInNoRoom state))}
    | otherwise = state {roomList = (newRoomList)}
    where
      newRoomList = map fun (roomList state)
      fun rm
          | rName == (roomName rm) = rm {userList = user : (userList rm)}
          | otherwise = rm

addonAction :: BState -> AddonUserName -> String -> (BState, [Line])
addonAction state name body
    | name == myNick state = (state, [])
    | otherwise = (state,
                   [IRCLine stuff]
                  )
    where
      stuff = ":" ++ (sanitizeName name) ++ " PRIVMSG " ++ 
              (channelName state) ++ " :\SOHACTION " ++
              (sanitizeAddonMessage state body) ++ "\SOH"

addonSpeech :: BState -> AddonUserName -> String -> (BState, [Line])
addonSpeech state name body
    | name == myNick state = (state, [])
    | otherwise = (state,
                   [IRCLine stuff]
                  )
    where
      stuff = ":" ++ (sanitizeName name) ++ " PRIVMSG " ++ 
              (channelName state) ++ " :" ++ (sanitizeAddonMessage state body)

ircHours :: BState -> String -> (BState, [Line])
ircHours state line = (state,
                       [IRCLine stuff]
                      )
    where
      stuff = (S.join "\n" (map roomLine (roomList state)))
      header = ":RoomHours NOTICE " ++ (channelName state) ++
               " :Room....Close....Reopen\n"
      roomLine room = 
          ":RoomHours NOTICE " ++ (channelName state) ++ " :" ++ (roomName room) ++ 
          "\n:RoomHours NOTICE " ++ (channelName state) ++ " :   Close: " ++ 
                      (prettyTime (timeZone state) (todayCloseTime room)) ++ 
          "\n:RoomHours NOTICE " ++ (channelName state) ++ " :   Reopen: "  ++
                      (prettyTime (timeZone state) (todayReopenTime room))
      
      

ircSignon :: BState -> String -> (BState, [Line])
ircSignon state line = (state, 
                        [IRCLine (":" ++ (myNick state) ++ 
                                              " JOIN :" ++ (channelName state)),
                         BridgeLine (ConnectToAddon (server state) (addonPort state))]
                       )

ircWho :: BState -> String -> (BState, [Line])
ircWho state line = (state,
                     [IRCLine stuff]
                    )
    where
      roomLine room = (S.join "\n" (map (makeLine (roomName room)) (userList room)))
      stuff = header ++ (S.join "\n" (map roomLine (roomList state))) ++ "\n" ++
              (S.join "\n" (map (makeLine "nowhere") (usersInNoRoom state)))
      makeLine rName user = ":UserList NOTICE " ++
                            (channelName state) ++ " :" ++
                            (ircUserName user) ++ "...." ++
                            rName ++ "...." ++ 
                            (show $ userColor user) ++ " " ++
                            (awayS user)
      header = ":UserList NOTICE " ++ (channelName state) ++ 
               " :User name....Room Name....Color\n"
      awayS user
          | userAwayState user == Away = "<<AWAY>>"
          | otherwise = ""

-- the action to take when kicked out of a room is different than in bridge
-- it doesn't put "wasKickedFromRoom" in the 73 message
ircMove :: BState -> String -> (BState, [Line])
ircMove state line
    | length (words line) < 2 = (state, [])
    | command == "list" = (state,
                           [IRCLine fun]
                          )
    | (null $ arg) = (state, [])
    | n < 0 || n >= length (roomList state) = (state, [])
    | curRoom == Nothing = (state,
                            [AddonLine 73 0 0 etx
                                        (roomName $ (roomList state)!!(read $ command))
                                        etx 1 0 0]
                           )
    | otherwise = (state {roomMove = roomName $ (roomList state)!!(read command)},
                              [AddonLine 6 0 0 (roomName room)
                                          etx etx 0 0 0]
                             )
    where
      curRoom = myCurrentRoom state
      Just room = curRoom
      command = (words line)!!1
      arg = (reads command) :: [(Int, String)]
      n = (fst . head) arg
      fun = S.join "\n" (map liner (zliner (roomList state)))
      zliner rList = zip rList (map show [0..])
      liner (room, index) = ":RoomList NOTICE " ++ (channelName state) ++
                            " :(" ++ index ++ ") " ++
                            (roomName room) ++ (mine room)
      mine room
          | curRoom == Nothing = ""
          | r == room = " ***"
          | otherwise = ""
          where
            Just r = curRoom

ircNames :: BState -> String -> (BState, [Line])
ircNames state line 
    | curRoom == Nothing = (state, [])
    | otherwise = (state, 
                              [IRCLine $ ":localhost 353 " ++
                                                  (myNick state) ++ " = " ++
                                                  (channelName state) ++ " :" ++
                                                  nameString room]
                             )
    where
      curRoom = myCurrentRoom state
      Just room = curRoom
      nameString r = S.join " " (nameList r)
      nameList r = map ircUserName (userList r)

ircPrivMsg :: BState -> String -> (BState, [Line])
ircPrivMsg state line
    | isNickServ = (state, [])
    | not isPM = (state,
                  [AddonLine addonNum 0 0 etx 
                                        (roomNameString $ myCurrentRoom state)
                                        (unsanitizeIRCMessage state extractBody)
                                        0 0 0]
                 )
    | otherwise = (state, 
                   [AddonLine 12 0 0 etx (ircToAddonName state ((words line)!!1))
                                         (unsanitizeIRCMessage state extractBody)
                                         0 0 0]
                  )
    where
      isPM = (words line)!!1 /= (channelName state)
      isNickServ = (words line)!!1 == "NickServ"
      addonNum
          | isAction = 15
          | otherwise = 5
      isAction = ":\SOHACTION" `isPrefixOf` (snd colonSplit)
      extractBody
          | isAction = (S.split ":\SOHACTION " (take ((length line) - 1) line))!!1
          | otherwise = tail $ snd colonSplit
      colonSplit = span (/= ':') line

ircPing :: BState -> String -> (BState, [Line])
ircPing state line = (state,
                      [IRCLine $ ":localhost PONG localhost :" ++ 
                                              (words line)!!1]
                     )

ircPass :: BState -> String -> (BState, [Line])
ircPass state line = (state {myPassword = (words line)!!1},
                      []
                     )

ircNick :: BState -> String -> (BState, [Line])
ircNick state line = (s, 
                      [IRCLine $ ircJoinMessage s]
                     )
  where
    s = state {myNick = (words line)!!1}
  

-- Find the room the user is in
currentRoom :: BState -> AddonUserName -> Maybe Room
currentRoom state aName 
    | null roomHesIn = Nothing
    | otherwise = Just $ head roomHesIn
    where
      roomHesIn = filter inRoom (roomList state)
      inRoom room = not (null $ filter (\x -> addonUserName x == aName) (userList room))

-- shortcut to find where I'm at
myCurrentRoom :: BState -> Maybe Room
myCurrentRoom state = currentRoom state (myNick state)

-- unwrap the name of a room from a Maybe Room
roomNameString :: Maybe Room -> String
roomNameString Nothing = "nowhere"
roomNameString (Just r) = (roomName r)

-- sanitize an addonchat username. take out spaces and punctuation
sanitizeName :: AddonUserName -> IRCUserName
sanitizeName aName = subRegex (mkRegex "[^a-zA-Z0-9]") aName "_"

-- turn an ircName into an addonName. Needs to be more complicated than the 
-- other wayp around because there's more than one way to turn them
ircToAddonName :: BState -> IRCUserName -> AddonUserName
ircToAddonName state iName 
    | null poss = iName
    | otherwise = addonUserName (head poss) 
                           
    where
      poss = filter nameRight allUsers
      allUsers = (usersInNoRoom state) ++ 
                 (concat $ map userList (roomList state))
      curRoom = myCurrentRoom state
      Just room = curRoom
      nameRight user = (ircUserName user) == iName


-- sanitize addonchat usernames to irc nicks and replace all html-ish markup
sanitizeAddonMessage :: BState -> String -> String
sanitizeAddonMessage state msg 
    | curRoom == Nothing = msg
    | otherwise = foldl' rep msg (wholeList room)
    where
      curRoom = myCurrentRoom state
      Just room = curRoom
      nameList r = zip (map (addonUserName) (userList r)) 
                 (map (ircUserName) (userList r))
      wholeList r = saniList ++ (nameList r)
      rep line (a, b) = subRegex (mkRegex a) line b

{- alist of non-name regex replacements-}
saniList = [("&lt;", "<"),
            ("&gt;", ">"),
            ("\\[/??[biu]\\]", "") --html [b] tags and such
           ]

unSaniList = [("<", "&lt;"),
              (">", "&gt;")
             ]

-- TODO replace < and > with html code
-- replace all irc nicks with addonchat usernames
unsanitizeIRCMessage :: BState -> String -> String
unsanitizeIRCMessage state msg 
    | curRoom == Nothing = msg
    | otherwise = foldl' rep msg (unSaniList ++ (nameList room))
    where
      curRoom = myCurrentRoom state
      Just room = curRoom
      nameList r = zip (map ircUserName (userList r))
                 (map addonUserName (userList r))
      rep line (a, b) = subRegex (mkRegex a) line b


prettyTime :: TimeZone -> Int -> String
prettyTime tz t = show (utcToLocalTime tz 
                        (posixSecondsToUTCTime (fromIntegral t)))

-- parse a string into an addonline
stringToAddonLine :: String -> Line
stringToAddonLine l = AddonLine f0 f1 f2 f3 f4 f5 f6 f7 f8
    where
      fields =  S.split "\t" l
      f0 = read $ fields!!0
      f1 = read $ fields!!1
      f2 = read $ fields!!2
      f3 = fields!!3
      f4 = fields!!4
      f5 = fields!!5
      f6 = read $ fields!!6
      f7 = read $ fields!!7
      f8 = read $ fields!!8



{- Create IRC server join message for nick -}
ircJoinMessage :: BState -> String
ircJoinMessage state = subRegex (mkRegex "QQQQ") initMessage (myNick state)

initMessage = ":localhost NOTICE AUTH : addonchat dealy\n:localhost 001 QQQQ :Welcome to the AddonChat/IRC gateway, QQQQ\n:localhost 002 QQQQ :Host localhost is running, barely Linux/x86_64.\n:localhost 003 QQQQ :Something\n:localhost 004 QQQQ localhost 3.0.3-1 abiswRo ntC\n:localhost 005 QQQQ PREFIX=(ohv)@%+ CHANTYPES=&# CHANMODES=,,,ntC NICKLEN=23 CHANNELLEN=23 NETWORK=AddonBridge SAFELIST CASEMAPPING=rfc1459 MAXTARGETS=1 WATCH=128 FLOOD=0/9999 :are supported by this server\n:localhost 375 QQQQ :- localhost Message Of The Day - \n:localhost 372 QQQQ :- Welcome to the AddonChat/IRC server at localhost.\n:localhost 372 QQQQ :- \n:localhost 372 QQQQ :- This server is running, barely.\n:localhost 372 QQQQ :- The newest version can't be found.\n:localhost 372 QQQQ :- \n:localhost 372 QQQQ :- You are getting this message because the server administrator has not\n:localhost 372 QQQQ :- yet had the time (or need) to change it.\n:localhost 372 QQQQ :- \n:localhost 372 QQQQ :- For those who don't know it yet, this is not quite a regular Internet\n:localhost 372 QQQQ :- Relay Chat server. Please see the site mentioned above for more\n:localhost 372 QQQQ :- information.\n:localhost 372 QQQQ :- \n:localhost 372 QQQQ :- \n:localhost 372 QQQQ :- The developers of the AddonChat/IRC Bridge hope you have a buzzing time.\n:localhost 372 QQQQ :- \n:localhost 372 QQQQ :- *\n:localhost 372 QQQQ :-  \n:localhost 372 QQQQ :- ... Buzzing, haha, get it?\n:localhost 376 QQQQ :End of MOTD\n:QQQQ!QQQQ@localhost MODE QQQQ :+s\n"

etx :: String
etx = "\ETX"