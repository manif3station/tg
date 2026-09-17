use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
use Test::CaptureStdio qw(run_capturing_stderr);

# TGT-286 (found via a scheduled JOB-003 hourly bug hunt): every other
# startup-time failure path in cli/poller.pl (lock_path, heartbeat_path,
# D2TG::Store->new - TGT-183/184/185) is eval-wrapped and refuses with a
# clean, fixed "... - refusing to start." STDERR message rather than
# letting a raw Perl exception escape. Both D2TG::Config::Flags::bot_groups
# calls (the validation-only pass and the real one) were never brought
# into that same convention - a malformed --chat_id shape dies raw
# instead. This test drives a malformed --chat_id (non-numeric) through
# the real poller.pl entrypoint and asserts the SAME clean refusal shape
# every other failure path already uses.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

my $fake_db_dir = tempdir( CLEANUP => 1 );
setup_mandatory_db_env( $Bin, $fake_db_dir );
local %ENV = %ENV;
delete $ENV{D2TG_TOKEN};
delete $ENV{D2TG_CHAT_ID};

my ( $out, $rc, $err ) = run_capturing_stderr( $poller_cli, '--chat_id', 'not-numeric', '--bot', 'sometoken' );

isnt( $rc, 0, 'a malformed --chat_id shape refuses to start (non-zero exit)' );
like(
    $err,
    qr/refusing to start/i,
    'refuses with this script\'s own established clean-refusal message, not a raw Perl exception'
);
unlike(
    $err,
    qr/D2TG::Config::Flags::bot_groups:/,
    'the raw module::function-qualified die message is not echoed verbatim to the user'
);

done_testing();
