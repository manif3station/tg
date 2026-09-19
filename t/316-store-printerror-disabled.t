use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

require D2TG::Store;

package main;

# TGT-316 (found via a scheduled JOB-003 hourly bug hunt, reproduced
# live in the perl-test container): D2TG::Store::new's DBI->connect set
# RaiseError => 1 but never PrintError => 0. DBI's own documented
# default for PrintError is 1 (true) - RaiseError and PrintError are
# independent attributes, and RaiseError alone does not suppress
# PrintError's own STDERR warning before the exception is raised. Live
# reproduction: held an EXCLUSIVE transaction on a test DB from a
# forked child, then ran cli/approve.pl against it from the parent -
# a raw, unclassified "DBD::SQLite::db do failed: database is locked
# at .../AccessControl.pm line 35." line appeared on STDERR BEFORE the
# intended clean "Failed to open local storage (database is locked) -
# refusing to start." refusal - exactly the raw-exception-leak class
# this project has fixed repeatedly (TGT-133/183/186/195/293/311), all
# of which assumed RaiseError alone was sufficient.

my ( $fh, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
close $fh;
unlink $db_path;

my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );

ok( !$store->{dbh}{PrintError},
    "D2TG::Store::new's DBI connection has PrintError disabled (falsy) - DBI's own default (1/true) does not get silently inherited" );

# Force a real DBI error and confirm nothing reaches STDERR except
# whatever the caller itself explicitly prints - PrintError must not
# add its own raw warning on top.
my $stderr = '';
{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    eval { $store->{dbh}->do('SELECT * FROM this_table_does_not_exist') };
}
ok( length $@, 'the forced DBI error still raises via RaiseError, unaffected by PrintError => 0' );
is( $stderr, '', 'no raw DBI/SQLite warning was printed to STDERR - PrintError => 0 actually suppressed it' );

done_testing();
