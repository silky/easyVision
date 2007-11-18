
import EasyVision
import ImagProc.Ipp.Core
import Control.Monad(when)
import Graphics.UI.GLUT
import Data.List(minimumBy)

addFeature fun cam = return $ do
    im' <- cam
    let im = modifyROI (shrink (100,200)) im'
    v <- fun im
    return (im, v)

-- normalized lbp histogram
lbpN t im = do
    h <- lbp t im
    let ROI r1 r2 c1 c2 = theROI im
        sc = (256.0::Double) / fromIntegral ((r2-r1-1)*(c2-c1-1))
    return $ map ((*sc).fromIntegral) (tail h)

featLBP sz = addFeature $
    \im -> yuvToGray im >>= resize8u sz >>= lbpN 8

main = do
    sz <- findSize

    (cam,ctrl) <- getCam 0 sz >>= featLBP (mpSize 5) >>= withPause

    prepare

    w <- evWindow (False,[]) "image" sz Nothing  (mouse (kbdcam ctrl))

    r <- evWindow () "recognized" (mpSize 10)  Nothing  (const (kbdcam ctrl))

    launch (worker cam w r)

-----------------------------------------------------------------

worker cam w r = do

    img@(orig,v) <- cam

    (click,pats) <- getW w
    when click $ putW w (False, img:pats)

    inWin w $ do
        drawImage orig
        pointCoordinates (size orig)
        setColor 0 0 0
        renderAxes
        setColor 1 0 0
        renderSignal (map (*1) v)

    when (not $ null pats) $ inWin r $ do
        drawImage $ fst $ minimumBy (compare `on` dist img) pats

-----------------------------------------------------

dist (_,u) (_,v) = sum $ map (^2) $ zipWith subtract u v

-----------------------------------------------------

mouse _ st (MouseButton LeftButton) Down _ _ = do
    (_,ps) <- get st
    st $= (True,ps)

mouse def _ a b c d = def a b c d