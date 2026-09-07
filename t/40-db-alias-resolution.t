use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);

require D2TG::Config;

{
    local $ENV{D2TG_DB};
    eval { D2TG::Config::resolve_alias_dir() };
    like( $@, qr/D2TG_DB.*--db.*-d/i, 'no --db flag and no D2TG_DB env var: dies naming the missing flag/env var (TGT-059)' );
    like( $@, qr/d2 paths/i, 'the refusal message points at d2 paths to see valid aliases' );
}

{
    local $ENV{D2TG_DB};
    my $dir = D2TG::Config::resolve_alias_dir( alias => 'foobar', paths => { foobar => '/tmp/foo/bar' } );
    is( $dir, '/tmp/foo/bar', 'a valid --db alias resolves to its d2 paths entry' );
}

{
    local $ENV{D2TG_DB} = 'envalias';
    my $dir = D2TG::Config::resolve_alias_dir( paths => { envalias => '/tmp/env/dir' } );
    is( $dir, '/tmp/env/dir', 'D2TG_DB env var is used as a fallback when no --db flag is given' );
}

{
    local $ENV{D2TG_DB} = 'ignored';
    my $dir = D2TG::Config::resolve_alias_dir( alias => 'explicit', paths => { explicit => '/tmp/explicit', ignored => '/tmp/ignored' } );
    is( $dir, '/tmp/explicit', 'an explicit --db alias takes precedence over the D2TG_DB env var' );
}

{
    local $ENV{D2TG_DB};
    eval { D2TG::Config::resolve_alias_dir( alias => 'nope', paths => { foobar => '/tmp/foo/bar' } ) };
    like( $@, qr/Unknown --db.*nope/i, 'an alias not present in paths dies with a clear message naming it' );
    like( $@, qr/d2 paths/i, 'the error message points at d2 paths to see valid aliases' );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $db_path = D2TG::Config::state_db_path( base_dir => $dir );
    is( $db_path, "$dir/store.sqlite", 'state_db_path with an explicit base_dir puts store.sqlite directly there, no state/ subdir' );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $files_dir = D2TG::Config::attachments_dir( base_dir => $dir );
    is( $files_dir, "$dir/files", 'attachments_dir with an explicit base_dir resolves to <base_dir>/files' );
    ok( -d $files_dir, 'attachments_dir creates the files/ directory if missing' );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $files_dir = D2TG::Config::attachments_dir( default_root => $dir );
    is( $files_dir, "$dir/files", 'attachments_dir without base_dir falls back to default_root/files, mirroring state_db_path' );
}

{
    my ( $alias, @rest ) = D2TG::Config::extract_db_flag( '--db', 'foobar', '123456', 'hello' );
    is( $alias, 'foobar', 'extract_db_flag pulls out the --db value' );
    is_deeply( \@rest, [ '123456', 'hello' ], 'extract_db_flag leaves the remaining args in order' );
}

{
    my ( $alias, @rest ) = D2TG::Config::extract_db_flag( '123456', '-d', 'foobar', 'hello' );
    is( $alias, 'foobar', 'extract_db_flag recognizes -d as well as --db, anywhere in the list' );
    is_deeply( \@rest, [ '123456', 'hello' ], 'extract_db_flag leaves the remaining args in order regardless of flag position' );
}

{
    my ( $alias, @rest ) = D2TG::Config::extract_db_flag( '123456', 'hello' );
    is( $alias, undef, 'extract_db_flag returns undef when neither --db nor -d is given' );
    is_deeply( \@rest, [ '123456', 'hello' ], 'extract_db_flag leaves args completely unchanged when the flag is absent' );
}

{
    # Exercises the real (non-injected-paths) branch of resolve_alias_dir,
    # i.e. _developer_dashboard_paths, without needing a real Developer
    # Dashboard install: pretend the module is already loaded (so
    # `require` is a no-op) and inject a fake d2() via typeglob, the same
    # spirit as D2TG::TTS::_run's tests using $^X as a stand-in command.
    local $ENV{D2TG_DB};
    $INC{'Developer/Dashboard.pm'} = 1;

    package Fake::Handle;
    sub paths { return { realpath_alias => '/tmp/real/path/test' } }

    package main;
    no strict 'refs';
    local *Developer::Dashboard::d2 = sub { return bless {}, 'Fake::Handle' };
    use strict 'refs';

    my $dir = D2TG::Config::resolve_alias_dir( alias => 'realpath_alias' );
    is( $dir, '/tmp/real/path/test', 'resolve_alias_dir with no paths override calls the real Developer::Dashboard::d2()->paths path' );

    delete $INC{'Developer/Dashboard.pm'};
}

done_testing();
