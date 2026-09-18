use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-296 (found via a user-requested comprehensive bug/improvement
# sweep): state_db_path, attachments_dir, lock_path, heartbeat_path
# each duplicated the identical "if base_dir given, resolve under
# .tira/, else fall back to DEVELOPER_DASHBOARD_SKILL_ROOT/
# default_root/... and a state/ or files/ dir, make_path if missing"
# logic, differing only in the final directory/filename. Collapsed
# onto one shared private helper - zero observable behavior change.

require D2TG::Config::Paths;

# Structural: the module now exposes one shared private helper, and
# each of the 4 public functions delegates to it.
{
    open my $fh, '<', $INC{'D2TG/Config/Paths.pm'} or die $!;
    local $/;
    my $source = <$fh>;
    close $fh;

    like( $source, qr/sub _resolve_state_path \{/, 'shared private helper _resolve_state_path is defined' );

    for my $fn (qw(state_db_path attachments_dir lock_path heartbeat_path)) {
        like( $source, qr/sub \Q$fn\E \{[^}]*_resolve_state_path\(/s,
            "$fn delegates to the shared helper" );
    }
}

# Behavioral: base_dir form, for all 4 functions.
my $dir = tempdir( CLEANUP => 1 );

is( D2TG::Config::Paths::state_db_path( base_dir => $dir ),
    File::Spec->catfile( $dir, '.tira', 'telegram.messages.db' ), 'state_db_path resolves under base_dir/.tira' );
is( D2TG::Config::Paths::attachments_dir( base_dir => $dir ),
    File::Spec->catdir( $dir, '.tira', 'attachments' ), 'attachments_dir resolves under base_dir/.tira/attachments' );
is( D2TG::Config::Paths::lock_path( base_dir => $dir ),
    File::Spec->catfile( $dir, '.tira', 'telegram.pid' ), 'lock_path resolves under base_dir/.tira' );
is( D2TG::Config::Paths::heartbeat_path( base_dir => $dir ),
    File::Spec->catfile( $dir, '.tira', 'telegram.heartbeat' ), 'heartbeat_path resolves under base_dir/.tira' );

# Behavioral: default_root fallback form (no base_dir), for all 4.
local $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT};
delete $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT};

my $root = tempdir( CLEANUP => 1 );

is( D2TG::Config::Paths::state_db_path( default_root => $root ),
    File::Spec->catfile( $root, 'state', 'store.sqlite' ), 'state_db_path falls back to default_root/state' );
is( D2TG::Config::Paths::attachments_dir( default_root => $root ),
    File::Spec->catdir( $root, 'files' ), 'attachments_dir falls back to default_root/files' );
is( D2TG::Config::Paths::lock_path( default_root => $root ),
    File::Spec->catfile( $root, 'state', 'poller.pid' ), 'lock_path falls back to default_root/state' );
is( D2TG::Config::Paths::heartbeat_path( default_root => $root ),
    File::Spec->catfile( $root, 'state', 'poller.heartbeat' ), 'heartbeat_path falls back to default_root/state' );

done_testing();
