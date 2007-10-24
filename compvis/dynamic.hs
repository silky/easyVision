-- virtual ball on an A4 sheet
-- ./dynamic tv://

module Main where

import EasyVision as EV
import System.Environment(getArgs)
import qualified Data.Map as Map
import Graphics.UI.GLUT hiding (Matrix, Size, Point)
import Vision
import Control.Monad(when)
import Numeric.LinearAlgebra
import Debug.Trace
import Data.IORef
import Control.Concurrent
import Text.Printf
import ImagProc.Ipp.Core
import qualified Graphics.UI.GLUT as GL
import System.CPUTime

timing act = do
    t0 <- getCPUTime
    act
    t1 <- getCPUTime
    printf "%.2f CPU seconds\n" $ (fromIntegral ((t1 - t0) `div` (10^10)) / 100 :: Double)

debug x = trace (show x) x

data Particle = PT {
    x,y,z :: GLdouble,
    vx,vy,vz :: GLdouble }

createParticle = do
    p <- newMVar PT {x=1,y=1.5,z=0,vx=0.000,vy=0.000,vz=0}
    a <- newMVar (0,0,0)
    let loop = do
        s <- readMVar p
        (ax,ay,az) <- readMVar a
        let vx1 = 0.995*vx s + ax
            vy1 = 0.995*vy s + ay
            svx = if x s <r || x s > 2.1-r then -vx1 else vx1
            svy = if y s <r || y s > 2.97-r then -vy1 else vy1
            vz1 = vz s + az
            x1  = x s + svx
            y1  = y s + svy
            z1  = z s + vz1
            r = 0.3
        swapMVar p s{x=x1,y=y1,z=z1,vx=svx,vy=svy,vz=vz1}
        threadDelay 10000
        loop
    let readPos = do
        s <- readMVar p
        return s
    let writeAccel ax ay az = do
        swapMVar a (ax,ay,az)
        return ()
    forkIO loop
    return (readPos, writeAccel)

data MyState = ST {
    rfloor :: Matrix Double,
    rprev  :: Matrix Double,
    reset :: Bool }

initstate = ST { rfloor = cameraAtOrigin,
                 rprev  = cameraAtOrigin,
                 reset = True }

main = do
    args <- getArgs

    let opts = Map.fromList $ zip args (tail args)

    let sz = if Map.member "--size" opts
                 then mpSize $ read $ Map.findWithDefault "20" "--size" opts
                 else Size (read $ Map.findWithDefault "480" "--rows" opts)
                           (read $ Map.findWithDefault "640" "--cols" opts)

    (cam,ctrl) <- mplayer (args!!0) sz  {- >>= inThread -} >>= withPause

    app <- prepare initstate

    o <- createParameters app [("radius",intParam 4 0 10),
                               ("width",realParam 1.5 0 5),
                               ("median",intParam 5 3 5),
                               ("high",intParam 40 0 255),
                               ("low",intParam 20 0 255),
                               ("postproc",intParam 1 0 1),
                               ("minlength",realParam 0.15 0 1),
                               ("maxdis",realParam 0.06 0 0.1),
                               ("orthotol",realParam 0.25 0.01 1),
                               ("method",intParam 1 0 2){-,
        ("umbral2",intParam 128 1 255),
        ("area",percent 1),
        ("fracpix",realParam (1.5) 0 10),
        ("white",intParam 1 0 1),
        ("eps",realParam 0.1 0 0.3),
        ("smooth2",intParam 1 0 10)-}]

    addWindow "virtual ball" sz Nothing mouse app

    depthFunc $= Just Less

    let mbf = read `fmap` Map.lookup "--focal" opts

    partic <- createParticle

    sv <- openYUV4Mpeg sz (Map.lookup "--save" opts)
                          (read `fmap` Map.lookup "--limit" opts)

    let capt = if "--save" `elem` args then capture sv else \a b c -> a b c

    launch app (worker cam o mbf partic capt)

-----------------------------------------------------------------


worker cam op mbf (getPos,setAccel) capt inWindow st = do

    method <- getParam op "method" :: IO Int
    radius <- getParam op "radius"
    width  <- getParam op "width"
    median' <- getParam op "median"
    high   <- fromIntegral `fmap` (getParam op "high" :: IO Int)
    low    <- fromIntegral `fmap` (getParam op "low" :: IO Int)
    postp  <- getParam op "postproc" :: IO Int
    let pp = if postp == 0 then False else True
    minlen <- getParam op "minlength"
    maxdis <- getParam op "maxdis"
    orthotol  <- getParam op "orthotol"
{-
    th2' <- getParam op "umbral2" ::IO Int
    let th2 = fromIntegral th2'
    smooth2 <- getParam op "smooth2" :: IO Int
    area <- getParam op "area"
    fracpix <- getParam op "fracpix"    
    white <- getParam op "white"
    eps <- getParam op "eps" ::IO Double
-}
    orig <- cam >>= yuvToGray

    let segs = filter ((>minlen).segmentLength) $ segments radius width median' high low pp orig
        polis = segmentsToPolylines maxdis segs
        closed4s = [p | Closed p <- polis, length p == 4]

{-
    im <-(smooth2 `times` median Mask3x3) orig

    let (Size h w) = size im
        pixarea = h*w*area`div`1000
        rawconts = contours 100 pixarea th2 (toEnum white) im
        proc = Closed . pixelsToPoints (size orig).douglasPeuckerClosed fracpix.fst3
        nice p@(Closed l) = perimeter p / fromIntegral (length l) > eps
        cs = map proc $ rawconts
        closed4c = map (\(Closed l) -> l) $ selectPolygons 0.05 4 $ filter nice cs
-}
        closed4 = case 1 {-method-} of
            0 -> []
            1 -> closed4s 
            --2 -> closed4c

        a4s = filter (isA4 mbf orthotol) (concatMap alter closed4)
        pts = head a4s
        camera = cameraFromPlane 1E-3 500 mbf (map pl pts) a4
        st' = case (reset st, length a4s >0, camera) of
            (True,True,Just(p,path)) -> st { reset = False, rfloor = p }
            _ -> st
        ok = case (length a4s >0, camera) of
            (True,Just _) -> True
            _ -> False

    capt inWindow "virtual ball" $ do
        clear [DepthBuffer]
        drawImage orig
        clear [DepthBuffer]
        pointCoordinates (size orig)

        {-
        setColor 0 0 1
        lineWidth $= 1
        renderPrimitive Lines $ mapM_ drawSeg segs
        -}
        setColor 1 0 0
        lineWidth $= 3
        mapM_ (renderPrimitive LineLoop . (mapM_ vertex)) closed4

        when ok $ do
            let Just (p,_) = camera
                r = rfloor st'

            clear [DepthBuffer]
            --dispR 5 (dropRows (rows path - 5) path)

            cameraView p (4/3) 0.1 100

            field

            pos <- getPos
            sphere (x pos) (y pos)

            let (invr,_) = toCameraSystem r
                (invp,_) = toCameraSystem p

                rel = invr <> inv (invp)
                ax = rel @@> (0,2)
                ay = rel @@> (1,2)

            --ds rel

            --pointCoordinates (size orig)
            --text2D 0.9 (-0.7) (show$ map (round.(*100)) $ [ax,ay])
            setAccel (ax/1000) (ay/1000) 0

    return st'

---------------------------------------------------------

a4 = [[   0,    0]
     ,[   0, 2.97]
     ,[2.10, 2.97]
     ,[2.10,    0]]

pl (Point x y) = [x,y]

alter pts = map (rotateList pts) [0 .. 3]

rotateList list n = take (length list) $ drop n $ cycle list

drawSeg s = do
    vertex $ (extreme1 s)
    vertex $ (extreme2 s)

fst3 (a,_,_) = a

isA4 mbf tol pts = ao < tol && cy < 0
    where mbomega = fmap omegaGen mbf
          ao = autoOrthogonality mbomega h
          h = estimateHomography (map pl pts) a4
          Just p = poseFromHomogZ0 mbf h
          (_,cy,_) = cameraCenter p
          omegaGen f = kgen (recip (f*f))

text2D x y s = do
    rasterPos (Vertex2 x (y::GLfloat))
    renderString Helvetica12 s


sphere x y = do
    lineWidth $=1
    setColor 1 0.5 0.5
    translate $ Vector3 x y 0.3
    renderQuadric 
        (QuadricStyle Nothing NoTextureCoordinates Outside FillStyle)
        (Sphere 0.29 10 10)
    setColor 0 0 0
    renderQuadric 
        (QuadricStyle Nothing NoTextureCoordinates Outside LineStyle)
        (Sphere 0.3 10 10)


v a b c = vertex $ Vertex3 a b (c::GLdouble)

field = preservingMatrix $ do
    let h = 2.97
    let w = 2.10
    let t = 0.3
    setColor 0.2 0.2 1
    renderPrimitive Polygon $ do
        v 0 0 0
        v 0 h 0
        v 0 h t
        v 0 0 t
        v 0 0 0
    renderPrimitive Polygon $ do
        v w 0 0
        v w h 0
        v w h t
        v w 0 t
        v w 0 0
    setColor 0.4 0.4 1
    renderPrimitive Polygon $ do
        v 0 0 0
        v w 0 0
        v w 0 t
        v 0 0 t
        v 0 0 0
    renderPrimitive Polygon $ do
        v 0 h 0
        v w h 0
        v w h t
        v 0 h t
        v 0 h 0
    setColor 0 0.6 0
    Graphics.UI.GLUT.scale 0.8 0.8 (0.8::GLdouble)
    translate $ Vector3 t t 0
    renderPrimitive Polygon $ do
        v 0 h 0
        v (w-2*t) 0 0
        v w 0 0
        v (2*t) h 0
    renderPrimitive Polygon $ do
        v 0 0 0
        v ((w-2*t)/2) (h/2) 0
        v ((w-2*t)/2+2*t) (h/2) 0
        v (2*t) 0 0

mouse rst (Char ' ') Down _ _ = do
    modifyIORef rst $ \s -> s {ust = (ust s) {reset = True}}

mouse _ _ _ _ _ = return ()

--ds = putStrLn . format "  " (printf "%.2f")

-----------------------------------------------------------------

-- readPixels extremely slow, useless
capture sv inWindow name fun = do
    inWindow name fun
    let sz = Size 480 640
    img <- image sz
    let C (Img {ptr = p}) = img
        EV.Size h' w' = sz
        w = (fromIntegral.toInteger) w'
        h = (fromIntegral.toInteger) h'
    pixelZoom $= (1,-1)
    timing $ readPixels (Position 0 0) (GL.Size w h) (PixelData GL.RGB UnsignedByte p)
    img' <- rgbToYUV img
    sv img'