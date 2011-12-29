{-# LANGUAGE NoMonomorphismRestriction #-}

---------------------------------------------------------------------------
{- |
Module      :  EasyVision.GUI.Interface
Copyright   :  (c) Alberto Ruiz 2006-11
License     :  GPL

Maintainer  :  Alberto Ruiz (aruiz at um dot es)
Stability   :  provisional

User interface tools

-}
-----------------------------------------------------------------------------

module EasyVision.GUI.Interface (
    -- * Interface
    runFPS, runIdle, runIt, interface, sMonitor, observe,
    -- * Tools
    prepare,
    evWindow, evWindow3D, evWin3D,
    launch, launchFreq,
    inWin, getW, putW, updateW, getROI,
    kbdcam, kbdQuit, keyAction, mouseGen, mouseGenPt, modif, withPause
) where

import EasyVision.GUI.Util
import EasyVision.GUI.Draw
import ImagProc.Base
import ImagProc.Ipp(Size(..),ippSetNumThreads,ROI(..),saveRGB')
import Graphics.UI.GLUT hiding (RGB, Matrix, Size, None)
import qualified Graphics.UI.GLUT as GL
import Data.IORef
import System.Process(system)
import System.Exit
import Control.Monad(when)
import System.Environment(getArgs)
import qualified Data.Map as Map
import Data.Map
--import EasyVision.GUI.Objects
import Data.Traversable
import Control.Applicative


-- | keyboard callback for camera control and exiting the application with ESC. p or SPACE pauses, s sets frame by frame mode.
kbdcam :: (IO (),IO(),IO()) -> KeyboardMouseCallback
kbdcam (pauseC,stepC,passC) = kbd where
    kbd (Char ' ') Down Modifiers {shift=Up} _ = pauseC
    kbd (Char ' ') Down Modifiers {shift=Down} _ = passC
    kbd (Char 's') Down _ _ = stepC
    kbd a b c d = kbdQuit a b c d

-- | keyboard callback for exiting the application with ESC or q, useful as default callback.
-- Also, pressing i saves a screenshot of the full opengl window contents.
kbdQuit :: KeyboardMouseCallback
kbdQuit (Char '\27') Down Modifiers {shift=Down} _ = leaveMainLoop >> system "killall mplayer" >> return ()
kbdQuit (Char '\27') Down Modifiers {ctrl=Down} _ = exitWith ExitSuccess
kbdQuit (Char '\27') Down _ _ = leaveMainLoop
kbdQuit (Char   'i') Down _ _ = captureGL >>= saveRGB' Nothing
kbdQuit a Down m _            = putStrLn (show a ++ " " ++ show m ++ " not defined")
kbdQuit _ _ _ _               = return ()


keyAction g1 upds g2 acts def w a b c d = do
    v <- getW w
    sz <- evSize `fmap` get windowSize
    roi <- getROI w
    case Prelude.lookup (a,b,c) upds of
        Just op -> putW w (g1 op roi sz d v) >> postRedisplay Nothing
        Nothing -> case Prelude.lookup (a,b,c) acts of
                        Just op -> g2 op roi sz d v
                        Nothing -> def a b c d

withPoint f sz (Position c r) = f p
  where
   [p] = pixelsToPoints sz [Pixel (fromIntegral r) (fromIntegral c)]

modif = Modifiers {ctrl = Up, shift = Up, alt = Up }

mouseGen acts = keyAction (const.const) acts id []

mouseGenPt acts = keyAction (const.withPoint) acts id []

-----------------------------------------------------------------

interface sz0 name st0 ft g1 upds g2 acts mbkeyDisp resultFun resultDisp cam = do
    (cam', ctrl) <- withPause cam
    firstTimeRef <- newIORef True
    w <- evWindow st0 name sz0 mbkeyDisp (keyAction g1 upds g2 acts (kbdcam ctrl))
    return $ do
        thing <- cam'
        firstTime <- readIORef firstTimeRef
        when firstTime $ ft w thing >> writeIORef firstTimeRef False
        state <- getW w
        roi <- getROI w
        let (newState, result) = resultFun roi state thing
        inWin w (prepZoom w >> renderIn w (resultDisp roi newState result))
        putW w newState
        return result

sMonitor name f = interface (Size 240 360) name 0 (const.const.return $ ()) (const.const.const) acts id [] Nothing (const (,)) g
  where
    g roi k x = r !! j
      where
        r = f roi x
        j = k `mod` length r
    acts = [((MouseButton WheelUp,   Down, modif), (+1))
           ,((SpecialKey  KeyUp,     Down, modif), (+1))
           ,((MouseButton WheelDown, Down, modif), pred)
           ,((SpecialKey  KeyDown,   Down, modif), pred)]

observe name f = interface (Size 240 360) name () (const.const.return $ ()) id [] id [] Nothing (const (,)) (const.const $ f)

-----------------------------------------------------------------

-- | Initializes the HOpenGL system.
prepare :: IO ()
prepare = do
    getArgsAndInitialize
    initialDisplayMode $= [DoubleBuffered, WithDepthBuffer]
    ippSetNumThreads 1
    return ()

-- | Starts the application with a worker function (idle callback).
launch :: IO () -> IO ()
launch worker = do
    idleCallback $= Just worker
    mainLoop

-- | Starts the application with a worker function which runs at the desired frequency (in Hz).
launchFreq :: Int -> IO () -> IO ()
launchFreq freq worker = do
    let callback = do
        addTimerCallback (1000 `div` freq) callback
        worker
    addTimerCallback 1000 callback
    mainLoop


runIdle :: IO (IO a) -> IO ()
runIdle c = prepare >> (c >>= launch . (>> return ()))

runFPS :: Int -> IO (IO a) -> IO ()
runFPS n c = prepare >> (c >>= launchFreq n . (>> return ()))

runIt f = prepare >> f >> mainLoop

----------------------------------------------------------------

evWindow st0 name size mdisp kbd = do
    st <- newIORef st0
    glw <- createWindow name
    windowSize $= glSize size
    let draw = case mdisp of
            Nothing -> return ()
            Just fun -> do
                clear [ColorBuffer]
                fun st
                swapBuffers
    displayCallback $= draw

    actionOnWindowClose $= ContinueExectuion

    let Size h w = size

    r <- newIORef ROI {r1=0, r2=h-1, c1=0, c2=w-1}
    zd <- newIORef (1,0,0)
    ms <- newIORef None
    po <- newIORef StaticSize
    ps <- newIORef Nothing

    let w = EVW { evW = glw
                , evSt = st
                , evROI = r
                , evZoom = zd
                , evMove = ms
                , evPolicy = po
                , evPrefSize = ps
                , evInit = clear [ColorBuffer] }

    keyboardMouseCallback $= Just (kbdroi w (kbd w))
    motionCallback $= Just (mvroi w)

    return w

---------------------------------------------------------------

inWin w f = do
    saved <- get currentWindow
    currentWindow $= Just (evW w)
    evInit w
    f
    swapBuffers
    currentWindow $= saved

getW = get . evSt
putW w x = evSt w $= x
updateW w f = evSt w $~ f

getROI = get . evROI

----------------------------------------------------------------

evWindow3D ist name sz kbd = do
    (trackball,kc,mc,_) <- newTrackball
    w <- evWindow ist name (Size sz sz) Nothing (kc kbd)
    motionCallback $= Just mc
    depthFunc $= Just Less
    textureFilter Texture2D $= ((Nearest, Nothing), Nearest)
    textureFunction $= Replace
    return w { evInit = clear [ColorBuffer, DepthBuffer] >> trackball}

-- provisional
evWin3D ist name sz mdisp kbd = do
    (trackball,kc,mc,auto) <- newTrackball
    w <- evWindow ist name (Size sz sz) Nothing (redik (kc kbd))
    motionCallback $= Just (redim mc)
    depthFunc $= Just Less
    textureFilter Texture2D $= ((Nearest, Nothing), Nearest)
    textureFunction $= Replace
    let draw = case mdisp of
            Nothing -> return ()
            Just fun -> do
                clear [ColorBuffer, DepthBuffer] >> trackball
                fun (evSt w)
                swapBuffers
    displayCallback $= draw
    let callback = do
        addTimerCallback 50 callback
        ok <- auto
        when ok $ postRedisplay (Just (evW w))
    addTimerCallback 1000 callback
    return w { evInit = clear [ColorBuffer, DepthBuffer] >> trackball}


redim f p = f p >> postRedisplay Nothing
redik f a1 a2 a3 a4 a5 = f a1 a2 a3 a4 a5 >> postRedisplay Nothing

----------------------------------------------------------------

minroi = 20

nextPolicy UserSize = DynamicSize
nextPolicy StaticSize = UserSize
nextPolicy DynamicSize = UserSize

kbdroi w _ (Char '0') Down Modifiers {alt=Down} _ = do
    mbsz <- readIORef (evPrefSize w)
    case mbsz of
        Nothing -> return ()
        Just (Size h w') -> writeIORef (evROI w) ROI {r1=0, r2=h-1, c1=0, c2=w'-1}

kbdroi w _ (MouseButton WheelUp) Down Modifiers {ctrl=Down} _ =
    modifyIORef (evZoom w) (\(z,x,y)->(z*1.1,x*1.1,y*1.1))
kbdroi w _ (MouseButton WheelDown) Down Modifiers {ctrl=Down} _ =
    modifyIORef (evZoom w) (\(z,x,y)->(z/1.1,x/1.1,y/1.1))

kbdroi w _ (SpecialKey KeyUp) Down Modifiers {ctrl=Down} _ =
    modifyIORef (evZoom w) (\(z,x,y)->(z*1.1,x*1.1,y*1.1))
kbdroi w _ (SpecialKey KeyDown) Down Modifiers {ctrl=Down} _ =
    modifyIORef (evZoom w) (\(z,x,y)->(z/1.1,x/1.1,y/1.1))


kbdroi w _ (MouseButton LeftButton) Down Modifiers {ctrl=Down} (Position x y) =
    writeIORef (evMove w) (MoveZoom x y)

kbdroi w _ (MouseButton RightButton) Down Modifiers {ctrl=Down} (Position x' y') = do
    ms <- readIORef (evMove w)
    z <- readIORef (evZoom w)
    vp <- get viewport
    let (x,y) = unZoom z vp (x',y') 
    modifyIORef (evROI w) (\ (ROI _ r2 _ c2) -> ROI (min (r2-minroi) y) r2 (min (c2-minroi) x) c2)
    writeIORef (evMove w) SetROI

kbdroi w _ (MouseButton LeftButton) Up _ _ = writeIORef (evMove w) None
kbdroi w _ (MouseButton RightButton) Up _ _ = writeIORef (evMove w) None

kbdroi w _ (SpecialKey KeyF3) Down _ _ = modifyIORef (evPolicy w) nextPolicy

kbdroi w _ (Char '0') Down Modifiers {ctrl=Down} _ = writeIORef (evZoom w) (1,0,0)

kbdroi _ defaultFunc a b c d = defaultFunc a b c d


mvroi w (Position x1' y1') = do
    ms <- readIORef (evMove w)
    z <- readIORef (evZoom w)
    vp <- get viewport
    let (x1,y1) = unZoom z vp (x1',y1') 
    case ms of
        None -> return ()
        SetROI -> modifyIORef (evROI w) $ 
                    \(ROI r1 _ c1 _) -> ROI r1 (max (r1+minroi) y1) c1 (max (c1+minroi) x1)
        MoveZoom x0 y0 -> do
            modifyIORef (evZoom w) $
                \(z,x,y) -> (z, x+fromIntegral (x1'-x0), y-fromIntegral (y1'-y0))
            writeIORef (evMove w) (MoveZoom x1' y1')

--------------------------------------------------------------------------------

withPause :: IO a                          -- ^ original camera
          -> IO (IO a, (IO(), IO(), IO())) -- ^ camera and controller (pause, step, pass)
withPause grab = do
    paused <- newIORef False
    frozen <- newIORef undefined
    step   <- newIORef False
    pass   <- newIORef False

    let pauseC = do
            modifyIORef paused not
            p <- readIORef paused
            if p then grab >>= writeIORef frozen
                 else return ()

        stepC = modifyIORef step not
        passC = modifyIORef pass not

        control = (pauseC,stepC,passC)

    let virtual = do
        s <- readIORef step
        p <- readIORef paused
        g <- readIORef pass
        let grab' = if g then grab >> readIORef frozen else readIORef frozen
        if not s && p
             then grab'
             else 
                if s then if p then grab'
                               else do writeIORef paused True
                                       grab >>= writeIORef frozen
                                       readIORef frozen
             else grab

    return (virtual,control)

