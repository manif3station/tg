use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Config;

{
    my $skill_root = tempdir( CLEANUP => 1 );
    local $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} = $skill_root;

    my $db_path = D2TG::Config::state_db_path();

    is(
        $db_path,
        File::Spec->catfile( $skill_root, 'state', 'store.sqlite' ),
        'state_db_path resolves under DEVELOPER_DASHBOARD_SKILL_ROOT/state'
    );
    ok( -d File::Spec->catdir( $skill_root, 'state' ), 'the state directory is created' );
}

{
    local $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} = '';
    delete $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT};

    my $db_path = D2TG::Config::state_db_path( default_root => '/tmp/d2tg-test-default-root' );

    like( $db_path, qr{/tmp/d2tg-test-default-root/state/store\.sqlite$},
        'falls back to the given default_root when the env var is unset' );
}

done_testing();
