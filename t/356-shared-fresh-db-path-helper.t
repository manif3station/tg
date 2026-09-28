#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";

# TGT-355 (found via a scheduled JOB-004 improvement hunt): fresh_db_path
# was duplicated byte-identically across 11 test files in two clusters
# (verified via md5sum, not assumed) - the same "found it twice, extract
# it" class TGT-153/TGT-203/TGT-353 already applied to this project's
# own test suite.

use Test::FreshDb qw(fresh_db_path);

my $path1 = fresh_db_path();
ok( !-e $path1, 'fresh_db_path returns a path to a file that does not yet exist' );
like( $path1, qr/\.sqlite$/, 'the path ends in .sqlite' );

my $path2 = fresh_db_path();
isnt( $path1, $path2, 'two calls return two distinct paths' );

done_testing();
