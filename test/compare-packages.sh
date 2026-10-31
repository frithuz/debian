#!/usr/bin/env bash
# Compare two package manifests (/var/lib/fai-build/packages.tsv from any two
# machines/images, or build/cloud.packages.tsv). Prints only the differences.
#
#   test/compare-packages.sh a.tsv b.tsv
#   test/compare-packages.sh <(ssh host1 cat /var/lib/fai-build/packages.tsv) \
#                            <(ssh host2 cat /var/lib/fai-build/packages.tsv)
#
# Exit 0 if identical, 1 if they differ.
set -euo pipefail
a=${1:?first manifest}; b=${2:?second manifest}

join -t $'\t' -a1 -a2 -e '-' -o 0,1.2,2.2 <(sort "$a") <(sort "$b") |
    awk -F'\t' -v A="$(basename "$a")" -v B="$(basename "$b")" '
        $2 != $3 { if (!n++) printf "%-36s %-28s %-28s\n", "package", A, B
                   printf "%-36s %-28s %-28s\n", $1, $2, $3 }
        END      { if (!n) print "identical (" NR " packages)"; else print n " differences"; exit (n > 0) }'
