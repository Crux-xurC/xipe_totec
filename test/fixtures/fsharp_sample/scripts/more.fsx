#load "tool.fsx"

System.IO.File.WriteAllText("TOP_LEVEL_RAN", "more.fsx")

let cube x = Tool.sq x * x
