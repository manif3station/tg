use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempdir);
use File::Spec;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Store;
require D2TG::Config;

# TGT-210 (found via a scheduled JOB-003 hourly bug hunt): cli/approve.pl's
# own POD SYNOPSIS and printed Usage message documented --bot <token> in
# a TRAILING position (after <chat_id>) - "d2 tg.approve <chat_id> [--db
# <alias> | -d <alias>] [--bot <token>]" - but D2TG::Reply::extract_bot_flag
# only ever recognizes --bot when it is the FIRST argument, the same
# leading-position shape cli/reply.pl's own --bot uses (TGT-057). The
# same file's own POD DESCRIPTION already correctly said so - only the
# SYNOPSIS/Usage text was wrong. A caller following the documented
# SYNOPSIS/Usage literally got an unconditional refusal, with the
# refusal's own Usage line showing that exact (broken) order as valid.
#
# This test derives the documented --bot/<chat_id> order directly from
# cli/approve.pl's own SYNOPSIS, then actually invokes the command in
# that exact order - so it fails red against the pre-fix SYNOPSIS
# (trailing order, which the real implementation refuses) and passes
# green once the SYNOPSIS is corrected to the order that really works.

sub read_source {
    open my $fh, '<', "$Bin/../cli/approve.pl" or die $!;
    local $/;
    return <$fh>;
}

my $source = read_source();
my ($synopsis) = $source =~ /=head1 SYNOPSIS\n\n(.*?)\n\n=head1/s;
die "SYNOPSIS section not found in cli/approve.pl's POD\n" unless $synopsis;

my ($synopsis_line) = grep { /--bot/ } split /\n/, $synopsis;
die "No SYNOPSIS line mentions --bot\n" unless defined $synopsis_line;

my ($chat_id_pos) = $synopsis_line =~ /()<chat_id>/;
my $chat_id_index = index( $synopsis_line, '<chat_id>' );
my $bot_index      = index( $synopsis_line, '--bot' );
die "SYNOPSIS line has neither <chat_id> nor --bot as documented\n"
  if $chat_id_index < 0 || $bot_index < 0;

my $bot_is_leading = $bot_index < $chat_id_index;

my $approve_cli = File::Spec->catfile( $Bin, '..', 'cli', 'approve.pl' );
my $skill_root  = tempdir( CLEANUP => 1 );

local %ENV = %ENV;
$ENV{D2TG_TOKEN}                     = 'test-token';
$ENV{D2TG_CHAT_ID}                   = '999';
$ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} = $skill_root;

setup_mandatory_db_env( $Bin, $skill_root );

my $db_path    = D2TG::Config::state_db_path( base_dir => $skill_root );
my $seed_store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
$seed_store->add_pending( 2000, 'tokenA' );

my @args = $bot_is_leading
  ? ( '--bot', 'tokenA', '2000' )
  : ( '2000', '--bot', 'tokenA' );

my $out = `$approve_cli @args 2>&1`;
my $rc  = $? >> 8;

is( $rc, 0, "cli/approve.pl invoked in the exact order its own SYNOPSIS documents (@args) exits 0" )
  or diag "SYNOPSIS line was: $synopsis_line\nOutput was: $out";
like( $out, qr/Approved 2000/, 'the documented invocation order actually approves the chat id, matching what the SYNOPSIS promises' );

my $check_store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
ok( $check_store->is_allowed( 2000, 'tokenA' ), 'the chat id is genuinely approved under the right bot scope' );

done_testing();
