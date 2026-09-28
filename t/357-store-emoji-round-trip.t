#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/lib";

use Test::FreshDb qw(fresh_db_path);
require D2TG::Store;

# TGT-357 (found via a scheduled JOB-003 hourly bug hunt, live-reproduced):
# D2TG::Store's own DBI->connect call had no sqlite_unicode flag -
# DBD::SQLite's documented behavior without it corrupts a non-BMP
# character (U+10000 and above - the range essentially all emoji live
# in) on round-trip through a TEXT column. Confirmed live: ASCII and
# accented Latin-1-range text (BMP-range) round-trip correctly; only a
# genuine emoji does not.

my $store = D2TG::Store->new( db_path => fresh_db_path() );

{
    my $text = 'hello world' x 5;
    $store->record_message( 1, 1, 'alice', $text );
    my $row = $store->get_message( 1, 1 );
    is( $row->{summary}, $text, 'plain ASCII summary round-trips correctly' );
}

{
    my $text = "caf\x{e9} r\x{e9}sum\x{e9}";
    $store->record_message( 2, 2, 'alice', $text );
    my $row = $store->get_message( 2, 2 );
    is( $row->{summary}, $text, 'accented Latin-1-range (BMP) summary round-trips correctly' );
}

{
    my $text = "hello \x{1F600} world";
    $store->record_message( 3, 3, 'alice', $text );
    my $row = $store->get_message( 3, 3 );
    is( $row->{summary}, $text, 'a summary containing a non-BMP emoji round-trips byte-for-byte correctly' );
}

done_testing();
