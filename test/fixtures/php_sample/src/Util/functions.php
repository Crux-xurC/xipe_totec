<?php

namespace App\Util;

function twice(int $x): int { return $x * 2; }

function thrice(int $x): int { return twice($x) + $x + strlen("x"); }
