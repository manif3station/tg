package Test::FreshDb;

use strict;
use warnings;
use Exporter qw(import);
use File::Temp qw(tempdir);
use File::Spec;

our @EXPORT_OK = qw(fresh_db_path);

# TGT-355 (found via a scheduled JOB-004 improvement hunt): fresh_db_path
# was duplicated byte-identically across 11 test files in two clusters
# (verified via md5sum, not assumed) - one using tempfile()+unlink, the
# other tempdir()+catfile - both functionally equivalent (a path to a
# not-yet-existing sqlite file, in a location cleaned up automatically,
# for D2TG::Store->new to create fresh). The tempdir()+catfile shape is
# used here - simpler, no explicit unlink needed - matching TGT-153's
# own "found it twice, extract it" precedent.

sub fresh_db_path {
    my $dir = tempdir( CLEANUP => 1 );
    return File::Spec->catfile( $dir, 'store.sqlite' );
}

1;

=head1 NAME

Test::FreshDb - shared test helper for a not-yet-existing sqlite db path

=head1 SYNOPSIS

    use Test::FreshDb qw(fresh_db_path);

    my $store = D2TG::Store->new( db_path => fresh_db_path() );

=head1 DESCRIPTION

TGT-355 (found via a scheduled JOB-004 improvement hunt): C<fresh_db_path>
was duplicated across many test files that each need a path to a
not-yet-existing SQLite database file, in a location that cleans itself
up automatically, for C<D2TG::Store>'s own C<CREATE TABLE IF NOT EXISTS>
schema bootstrap to run against on first connect.

=head1 FUNCTIONS

=head2 fresh_db_path()

Returns a path (inside a fresh C<File::Temp::tempdir>, C<CLEANUP =E<gt> 1>)
ending in C<store.sqlite> that does not yet exist. Each call returns a
distinct path.

=cut
