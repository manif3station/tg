use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store::Schema;

package main;

# TGT-318 (found via a scheduled JOB-004 improvement hunt, reviewing
# D2TG::Store::Schema.pm after TGT-317's own cleanup of the same file):
# 6 call sites duplicated the exact same shape - eval { $dbh->do("ALTER
# TABLE ... ADD COLUMN ...") }; die $@ if $@ && $@ !~ /duplicate column
# name/; - differing only by the literal ALTER TABLE SQL. Extracted
# into one shared _add_column_if_missing($dbh, $sql) helper, called
# from all 6 sites. Pure refactor: byte-identical behavior for every
# existing scenario.
#
# Matching TGT-279/313/314's own precedent for a pure-extraction
# refactor - a can()-based structural test rather than a new-behavior
# test, since there is no new behavior.

ok( D2TG::Store::Schema->can('_add_column_if_missing'),
    'D2TG::Store::Schema::_add_column_if_missing exists - the shared helper collapsing all 6 ALTER TABLE ADD COLUMN call sites' );

done_testing();
