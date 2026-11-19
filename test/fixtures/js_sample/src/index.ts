import './side-effect.css'
import main, { add as plus } from './util.js'
import * as u from './util'
import {
  twice, // a comment inside
} from "./util"

export function run(x: number): number {
  return plus(x, 1) + u.twice(x) + main(x)
}

const typed = <T>(x: T): T => twice(x as any)

class K {
  method() {
    return run(1)
  }
}

export { typed }
