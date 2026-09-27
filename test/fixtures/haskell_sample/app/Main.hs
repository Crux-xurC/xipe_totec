module Main (main, greet) where

import Geo.Shape (perimeter)

greet :: String -> String
greet name = "hello " ++ name ++ " " ++ show (perimeter 1 2)

main :: IO ()
main = putStrLn "MAIN RAN"
