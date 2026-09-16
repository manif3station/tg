use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-260: D2TG::Config.pm had grown to 1131 lines. Its 12-sub
# path/alias-resolution cluster (~352 lines, the largest cohesive
# concern in the file) is the largest cleanly-separable candidate -
# this proves the extracted D2TG::Config::Paths module works
# standalone, independent of D2TG::Config itself.
require D2TG::Config::Paths;

my $dir = tempdir( CLEANUP => 1 );

# --- state_db_path / attachments_dir / lock_path / heartbeat_path (base_dir form) ---
{
    my $db_path = D2TG::Config::Paths::state_db_path( base_dir => $dir );
    is( $db_path, File::Spec->catfile( $dir, '.tira', 'telegram.messages.db' ), 'state_db_path resolves under base_dir/.tira' );
    ok( -d File::Spec->catdir( $dir, '.tira' ), 'state_db_path creates the .tira directory' );

    my $att_dir = D2TG::Config::Paths::attachments_dir( base_dir => $dir );
    is( $att_dir, File::Spec->catdir( $dir, '.tira', 'attachments' ), 'attachments_dir resolves under base_dir/.tira/attachments' );

    my $lock = D2TG::Config::Paths::lock_path( base_dir => $dir );
    is( $lock, File::Spec->catfile( $dir, '.tira', 'telegram.pid' ), 'lock_path resolves under base_dir/.tira' );

    my $hb = D2TG::Config::Paths::heartbeat_path( base_dir => $dir );
    is( $hb, File::Spec->catfile( $dir, '.tira', 'telegram.heartbeat' ), 'heartbeat_path resolves under base_dir/.tira' );
}

# --- write_heartbeat / heartbeat_age ---
{
    my $hb_path = File::Spec->catfile( $dir, 'hb' );
    D2TG::Config::Paths::write_heartbeat($hb_path);
    ok( -f $hb_path, 'write_heartbeat creates the file' );

    my $age = D2TG::Config::Paths::heartbeat_age($hb_path);
    ok( defined $age && $age >= 0, 'heartbeat_age reads a fresh non-negative age' );

    is( D2TG::Config::Paths::heartbeat_age( File::Spec->catfile( $dir, 'nope' ) ), undef, 'heartbeat_age returns undef for a missing file' );
}

# --- resolve_alias_dir / resolve_alias_dir_or_die ---
{
    my $paths = { myalias => '/some/real/path' };
    is( D2TG::Config::Paths::resolve_alias_dir( alias => 'myalias', paths => $paths ), '/some/real/path', 'resolve_alias_dir resolves a known alias' );

    eval { D2TG::Config::Paths::resolve_alias_dir( alias => 'unknownalias', paths => $paths ) };
    like( $@, qr/Unknown --db\/-d alias/, 'resolve_alias_dir dies on an unknown alias' );

    eval { D2TG::Config::Paths::resolve_alias_dir( alias => undef, tira_home => undef, paths => $paths ) };
    like( $@, qr/D2TG_DB.*is not set/, 'resolve_alias_dir dies with no alias and no TIRA_HOME' );
}

# --- require_existing_base_dir / require_existing_base_dir_or_die ---
{
    is( D2TG::Config::Paths::require_existing_base_dir($dir), $dir, 'require_existing_base_dir accepts an existing directory' );

    eval { D2TG::Config::Paths::require_existing_base_dir( File::Spec->catdir( $dir, 'nope' ) ) };
    like( $@, qr/does not exist/, 'require_existing_base_dir dies on a missing directory' );
}

# --- resolve_self_exec_path ---
{
    my $existing = File::Spec->catfile( $dir, 'exists.pl' );
    open my $fh, '>', $existing or die $!;
    close $fh;

    is( D2TG::Config::Paths::resolve_self_exec_path( bin_dir => $dir, basename => 'exists.pl' ), $existing, 'resolve_self_exec_path finds an existing candidate' );
    is( D2TG::Config::Paths::resolve_self_exec_path( bin_dir => $dir, basename => 'missing.pl', fallback => 'FALLBACK' ), 'FALLBACK', 'resolve_self_exec_path falls back when the candidate is missing' );
}

done_testing();
