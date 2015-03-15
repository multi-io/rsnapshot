#!/bin/sh

t0=$(date +%s)

for i in `seq 1 5`; do
    ./lockfiletest.pl &
done

wait

t1=$(date +%s)

echo "$0 done, time: $[ $t1 - $t0 ] secs"
