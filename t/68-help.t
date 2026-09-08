use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-089 (live user request): d2 tg.help prints SKILLS.md and
# docs/commands.md so an agent unfamiliar with this skill can self-serve
# documentation via the CLI, without needing to know the skill's own
# install path on disk. Requires no env vars/flags at all - it touches
# no state, just prints static files.

my $help_cli = File::Spec->catfile( $Bin, '..', 'cli', 'help' );

{
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};
    delete $ENV{D2TG_DB};

    my $out = `"$^X" "$help_cli" 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'd2 tg.help exits 0 with no env vars/flags set at all' );

    like( $out, qr/tg — onboarding runbook/, 'output includes SKILLS.md content' );
    like( $out, qr/tg — command reference/,  'output includes docs/commands.md content' );

    my $skills_pos   = index( $out, 'tg — onboarding runbook' );
    my $commands_pos = index( $out, 'tg — command reference' );
    ok( $skills_pos < $commands_pos, 'SKILLS.md content appears before docs/commands.md content' );
}

done_testing();
