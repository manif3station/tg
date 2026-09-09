#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Telegram;
use D2TG::Poller;
use D2TG::Store;
use D2TG::Download;
use D2TG::Transcribe;
use D2TG::Lock;

# Autoflush STDOUT. Without this, STDOUT is fully block-buffered once
# connected to a pipe (as it always is under a Tira monitor job or any
# other non-TTY consumer) - since TGT-028 made this loop resilient to
# transient failures instead of dying on the first one, the process no
# longer exits promptly to force a flush, so every line (including real
# inbound messages) could sit unflushed indefinitely instead of reaching
# the watched stream in real time. STDERR is unbuffered by default.
$| = 1;

# TGT-117 (live-experienced incident): a message containing non-Latin-1
# script (a Cantonese voice-note transcript) triggered "Wide character
# in print at .../D2TG/Poller.pm line 83" - D2TG::Poller prints message
# text via an unqualified print (Perl's currently selected default
# output handle, ordinarily STDOUT) and errors via warn (which always
# targets STDERR), without opening either with a UTF-8 layer itself, since
# that's this entrypoint's job, not the library's. Non-fatal (the
# message still printed and was still processed correctly) but noisy,
# and repeats for every message with a character outside Latin-1 (not
# every non-ASCII one - Latin-1 itself covers many accented Latin
# characters). Applied at startup, before
# option handling and any poller work, so every print/warn path below
# (including --help's own usage text) is covered.
# TGT117-UTF8-LAYER-BEGIN (t/87 extracts and runs these exact two lines
# in a real subprocess - keep this block to just the binmode calls)
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
# TGT117-UTF8-LAYER-END

# TGT-107 (live-experienced incident): --help - or any other flag this
# script doesn't recognize - used to be silently accepted and ignored,
# letting the process fall all the way through to a real poll loop.
# Because D2TG::Lock's "last one wins" (TGT-084) SIGKILLs whichever
# process already holds the lock, that made a single typo (or an
# attempt to check usage) a real way to take a live poller offline. This
# check must run before ANYTHING else - including before --db/-d is
# even parsed - since --help must never depend on the rest of argv
# being well-formed.
if ( grep { $_ eq '--help' || $_ eq '-h' } @ARGV ) {
    print "Usage: d2 tg.poller [--db <alias> | -d <alias>] [--chat_id <id> --bot <token> ...]\n";
    print "  --db/-d <alias>   Developer Dashboard path alias for storage (or set D2TG_DB)\n";
    print "  --chat_id <id>    start a bot/chat group (repeatable)\n";
    print "  --bot <token>     attach a bot token to the current --chat_id group (repeatable)\n";
    print "  --help/-h         print this message and exit\n";
    exit 0;
}

# Preserved separately from the parsed/stripped @ARGV below: the
# self-restart exec() further down must re-exec with the ORIGINAL
# arguments (including --db, if given), not the already-parsed
# remainder - otherwise a version-triggered restart would silently lose
# the --db override and fall back to the default storage location.
my @original_argv = @ARGV;

my ( $db_alias, @rest );
eval { ( $db_alias, @rest ) = D2TG::Config::extract_db_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @rest;

# TGT-107 (Codex review finding): validate every remaining CLI token is
# a recognized --chat_id/--bot pair BEFORE the D2TG_CHAT_ID-missing
# guard below - otherwise, whenever D2TG_CHAT_ID happens to be unset,
# that guard fires first and masks an unrecognized-flag error behind
# its own, less specific message (an earlier version of this fix had
# exactly that gap). This validation must NOT depend on env vars at all
# (env_chat_id/env_token => undef bypasses bot_groups' own env-folding),
# so it can't itself die on an unrelated env-only misconfiguration
# (a bare D2TG_TOKEN with no D2TG_CHAT_ID/--chat_id makes bot_groups'
# real, env-folding call die with "--bot given before any --chat_id" -
# irrelevant here, since this pass only looks at what the CLI itself
# declared).
my ( undef, @cli_leftover ) = D2TG::Config::bot_groups(
    argv         => [@ARGV],
    env_chat_id  => undef,
    env_token    => undef,
);
if (@cli_leftover) {
    print STDERR "Unrecognized argument(s): " . join( ' ', @cli_leftover ) . "\n";
    exit 1;
}

# Multi-bot/multi-chat support (TGT-049): peek whether the CLI declared
# any --chat_id groups BEFORE consuming them, so the original single-var
# startup guard (exact message, for exact backward compatibility) only
# fires for the plain env-var-only case - CLI-declared groups supply
# their own chat ids independently of D2TG_CHAT_ID.
my $has_cli_groups = grep { $_ eq '--chat_id' } @ARGV;
exit 1 if !$has_cli_groups && !D2TG::Config::require_chat_id_or_warn();

my ( $groups, @leftover ) = D2TG::Config::bot_groups( argv => [@ARGV] );
@ARGV = @leftover;

my $base_dir = eval { D2TG::Config::resolve_alias_dir( alias => $db_alias ) };
if ($@) {
    print STDERR $@;
    exit 1;
}

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

# TGT-062: refuse to start a second instance against the same storage
# location - a prior poller merely suspended (Ctrl-Z, not killed) still
# holds a live connection to Telegram and would otherwise silently
# compete with this one for the same bot's getUpdates slot. TGT-087: the
# lock lives at .tira/telegram.pid under the resolved vault, matching
# TGT-081's own nesting of the other vault-resident files.
my $lock_path = D2TG::Config::lock_path(
    default_root => File::Spec->catdir( $Bin, '..' ),
    base_dir     => $base_dir,
);
eval { D2TG::Lock::acquire($lock_path) };
if ($@) {
    print STDERR $@;
    exit 1;
}

# TGT-113 (live-experienced incident: a poller crashed mid-version-bump
# race, never auto-restarted, and a SEPARATE orphaned instance under a
# different PID - with a stale command line missing '-d tira' - was
# found still running the entire time, competing for the same bot
# token's getUpdates queue). TGT-084's lock-eviction above only ever
# sees whichever single PID the LOCK FILE currently names; it has no
# way to notice a second process that never touched this lock file at
# all. This is a best-effort report, not a refusal: killing a process
# found only via a cmdline pattern match risks killing something that
# merely looks like a poller (a different project's own copy, or a
# developer's editor with the file open), so this warns loudly on
# STDERR and continues rather than acting unilaterally on a guess.
my @other_pollers = D2TG::Lock::find_other_pollers( own_pid => $$ );
if (@other_pollers) {
    print STDERR "WARNING: possible orphaned poller instance(s) detected "
      . "(PID(s): " . join( ', ', @other_pollers ) . ") - still running and "
      . "not tracked by this instance's own lock file. If genuinely another "
      . "live poller sharing this bot token, it may be competing for the "
      . "same getUpdates long-poll slot; investigate and stop it manually.\n";
}

# TGT-116: a heartbeat, separate from the lock file - written after each
# bot/chat pair's own poll cycle below, unconditionally, regardless of
# whether any message/error activity happened. This is what lets "the
# loop is still genuinely cycling" be distinguished from "alive but
# wedged" (a real, confirmed message-loss incident this session: a
# poller stayed alive and holding its lock for 80+ minutes while doing
# nothing at all).
my $heartbeat_path = D2TG::Config::heartbeat_path(
    default_root => File::Spec->catdir( $Bin, '..' ),
    base_dir     => $base_dir,
);

if ( !@$groups ) {
    print STDERR "No --chat_id/--bot groups configured (neither via CLI nor D2TG_CHAT_ID/D2TG_TOKEN) - refusing to start.\n";
    exit 1;
}

# Byte-identical to pre-TGT-049 behavior in the single-group/single-bot
# case: the startup line, and the offset meta key (see below), are both
# unchanged so an existing install upgrades with no migration step.
my $single_bot_mode = ( @$groups == 1 && @{ $groups->[0]{bots} } == 1 );

my $shutting_down = 0;
$SIG{TERM} = sub { $shutting_down = 1; D2TG::Transcribe::kill_current() };
$SIG{INT}  = sub { $shutting_down = 1; D2TG::Transcribe::kill_current() };

my $skill_root = File::Spec->catdir( $Bin, '..' );

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => $skill_root,
        base_dir      => $base_dir,
    ),
    admin_chat_id => [ map { $_->{chat_id} } @$groups ],
);

my @pairs;
for my $group (@$groups) {
    for my $token ( @{ $group->{bots} } ) {
        my $bot_key = $single_bot_mode ? undef : $token;
        push @pairs, {
            telegram => D2TG::Telegram->new( token => $token ),
            bot_key  => $bot_key,
            offset   => $store->get_offset($bot_key),
        };
    }
}

if ( !@pairs ) {
    print STDERR "No bot tokens configured (a --chat_id group with no --bot, and D2TG_TOKEN not set) - refusing to start.\n";
    exit 1;
}

if ($single_bot_mode) {
    print "d2tg poller starting up (token: "
        . D2TG::Config::masked_token( $groups->[0]{bots}[0] )
        . ") (chat_id: "
        . $groups->[0]{chat_id} . ")\n";
}
else {
    print "d2tg poller starting up with " . scalar(@$groups) . " group(s):\n";
    for my $group (@$groups) {
        print "  chat_id $group->{chat_id}: " . scalar( @{ $group->{bots} } ) . " bot(s) ("
            . join( ', ', map { D2TG::Config::masked_token($_) } @{ $group->{bots} } ) . ")\n";
    }
}

my $starting_version = D2TG::Config::skill_version( default_root => $skill_root );

my $attachments_dir = D2TG::Config::attachments_dir(
    default_root => $skill_root,
    base_dir      => $base_dir,
);

my $transcribe_voice = sub {
    my ( $tg, $file_id ) = @_;

    # Deliberately NOT passed dir => $attachments_dir: this download is
    # transient (unlinked immediately below), so it must never land in
    # the shared, deduplicated attachment vault - doing so and then
    # unlinking it would risk deleting a still-referenced photo/document
    # that happens to share the exact same content hash.
    my $local_path = D2TG::Download::download_file( $tg, $file_id );
    my $text = eval { D2TG::Transcribe::transcribe($local_path) };
    my $error = $@;
    unlink $local_path;
    die $error if $error;
    return $text;
};

my $download_media = sub {
    my ( $tg, $file_id ) = @_;
    return D2TG::Download::download_file( $tg, $file_id, dir => $attachments_dir );
};

until ($shutting_down) {
    for my $pair (@pairs) {
        last if $shutting_down;

        $pair->{offset} = D2TG::Poller::run_once_safe(
            $pair->{telegram}, $pair->{offset}, $store,
            transcribe_voice => $transcribe_voice,
            download_media   => $download_media,
            bot_token        => $pair->{bot_key},
        );
        $store->set_offset( $pair->{offset}, $pair->{bot_key} ) if defined $pair->{offset};

        # TGT-116 (Codex review finding): written after EACH pair, not
        # once after the whole for-loop - a single voice transcription
        # can legitimately take up to 900s on its own (D2TG::Transcribe's
        # 3-tier retry ladder, 300s per tier), and multiple pairs are
        # processed serially in one cycle. Writing only once per full
        # cycle could report a healthy, actively-working poller as STALE
        # during exactly the kind of long-running work this project has
        # already hit live (TGT-100).
        D2TG::Config::write_heartbeat($heartbeat_path);
    }
    D2TG::Download::prune_vault($attachments_dir);

    unless ($shutting_down) {
        my $current_version = D2TG::Config::skill_version( default_root => $skill_root );
        if ( $current_version ne $starting_version ) {
            print "d2tg poller detected version change ($starting_version -> $current_version), restarting...\n";
            $store->disconnect;

            # TGT-094 (live production incident): $0 is the path this
            # process was originally launched with, captured once at
            # startup. An install that renames this very file out from
            # under a still-running process (as TGT-093 did for real)
            # leaves $0 pointing at a path that no longer exists, so a
            # blind exec($0) dies instead of restarting. $Bin, though,
            # only depends on the script's DIRECTORY, which a rename
            # doesn't change - re-checking for the known current
            # basename there finds the live file regardless.
            my $exec_path = D2TG::Config::resolve_self_exec_path(
                bin_dir  => $Bin,
                basename => 'poller.pl',
                fallback => $0,
            );
            exec( $^X, $exec_path, @original_argv ) or die "d2tg poller: exec failed: $!\n";
        }
    }
}

D2TG::Lock::release($lock_path);
exit 0;

=head1 NAME

poller - tg skill entrypoint, dispatched as C<d2 tg.poller>

=head1 SYNOPSIS

    d2 tg.poller [--db <alias> | -d <alias>]
    d2 tg.poller --chat_id <id> --bot <token> [--bot <token> ...] [--chat_id <id> --bot <token> ...]
    d2 tg.poller --help

=head1 DESCRIPTION

At startup - before option handling and any poller work, though after
Perl compiles the C<use>d modules above - C<STDOUT> and C<STDERR> are
opened with an explicit C<:encoding(UTF-8)> layer (TGT-117, a
live-experienced incident: a real inbound Cantonese voice-note
transcript triggered a repeated "Wide character in print" warning,
since L<D2TG::Poller> prints message text via an unqualified C<print>
and errors via C<warn>, without opening either stream with a UTF-8
layer itself - that is this entrypoint's job, not the library's). The
warning was never fatal (the message was still processed and delivered
correctly either way), just noisy on every non-Latin-1 message; this
eliminates it for every print/warn path below, including C<--help>'s
own usage text.

C<--help>/C<-h> (TGT-107, a live-experienced incident) prints a short
usage summary and exits 0 immediately - checked before anything else,
including before C<--db>/C<-d> is even parsed, so C<--help> never
depends on the rest of C<@ARGV> being well-formed. Any OTHER argument
this script does not recognize as C<--db>/C<-d> or a valid
C<--chat_id>/C<--bot> group also refuses (STDERR names the specific
unrecognized token, exit 1) - both checks complete fully before the lock
below is ever acquired, since acquiring the lock is itself the dangerous
side effect: this project's C<D2TG::Lock> "last one wins" (TGT-084)
C<SIGKILL>s whichever process already holds it, so a single typo used to
be a real way to take a live, legitimate poller offline by silently
starting a second one.

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback env var) names a Developer Dashboard path alias (see C<d2
paths>) whose directory this run's SQLite state file and downloaded
attachments should live under, instead of the default skill-root-based
location - unknown alias refuses to start with a clear STDERR message.
See L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090, see L<D2TG::Config/require_existing_base_dir>).

Immediately after resolving that location, this process acquires an
exclusive lock there (TGT-062, C<poller.pid> - see L<D2TG::Lock>) and
refuses to start if another live process already holds it, since
Telegram allows only one active C<getUpdates> long-poll consumer per
bot token; a previous process merely suspended (C<Ctrl-Z>, not killed)
still holding that connection was found to silently compete with a
freshly started one for the same updates, with no signal-based fix able
to reach a stopped process. The lock releases on a clean C<SIGTERM>/
C<SIGINT> shutdown; a stale lock left by an unclean death is reclaimed
automatically on the next start.

Immediately after acquiring that lock, also checks
L<D2TG::Lock/find_other_pollers> and warns on STDERR, naming any PID(s)
found, if another live process's command line looks like a poller
instance (TGT-113, a live-experienced incident: a poller crashed
mid-restart and left an orphaned second instance under a different PID
still running, undetected, competing for the same bot token's
C<getUpdates> queue - the lock-eviction above only ever sees whichever
single PID the lock FILE currently names, not every process actually
polling). This is a report only, never a kill - see
L<D2TG::Lock/find_other_pollers> for why.

C<--chat_id <id>>/C<--bot <token>> (TGT-049, repeatable) declare one or
more bot/chat groups: each C<--chat_id> starts a new group, and each
following C<--bot> attaches to it, so multiple bots can be polled under
multiple admin chat ids in a single process. C<D2TG_CHAT_ID>/
C<D2TG_TOKEN> fold in as an implicit trailing group rather than being a
separate code path - see L<D2TG::Config/bot_groups> for the exact
merge rule (which also documents why the plain single-env-var case,
with no C<--chat_id>/C<--bot> given at all, is byte-identical to this
skill's original single-bot behavior). All declared chat ids are seeded
into the allow-list. Every (chat_id, bot) pair is polled sequentially,
round-robin, once per poll cycle - not one process per bot - each with
its own L<D2TG::Telegram> instance and its own persisted offset (see
L<D2TG::Store/get_offset>); the single-bot case keeps using the
original, unhashed offset key so an existing install upgrades with no
migration step. Refuses to start (STDERR, exit 1) if no group ends up
with at least one bot token.

Calls L<D2TG::Config>'s original startup guard only when no CLI
C<--chat_id> was given at all (so CLI-declared groups aren't blocked by
an unset C<D2TG_CHAT_ID>, which only matters for the plain env-var-only
case), refuses to proceed (non-zero exit, nothing on STDOUT) when
C<D2TG_CHAT_ID> is missing in that case. Once past every guard, prints a
startup line naming each group's chat id and its bots' masked tokens
(L<D2TG::Config/masked_token>, TGT-045; the single-bot case keeps the
original one-line format verbatim), opens a L<D2TG::Store> (auto-
seeding every declared chat id as allowed), resumes each pair's own
persisted poll offset if any, and runs L<D2TG::Poller>'s long-poll loop
for every pair in turn - gated by that shared store, saving each pair's
own offset back after its own iteration - until C<SIGTERM> or C<SIGINT>
is received. An allow-listed sender's voice message is downloaded (L<D2TG::Download>)
and transcribed via a local Whisper install (L<D2TG::Transcribe>); the
downloaded temp file is removed either way. A photo or document message
is downloaded via L<D2TG::Download> and its local path printed (kept,
unlike the transient voice download). Kept downloads are content-
addressed (TGT-051, named by their own SHA256 hash) under
L<D2TG::Config/attachments_dir>, so identical content sent any number of
times only ever occupies one copy of disk space; the transient voice
download deliberately does not use this shared, deduplicated location
(see the code comment on C<transcribe_voice>). A download or transcription
failure is reported on STDERR and does not stop the loop. The loop
itself runs via C<run_once_safe> (TGT-028), so a transient failure
inside the poll cycle (e.g. a network blip) is logged as C<POLL ERROR>
on STDERR and retried after a short backoff, rather than killing the
whole process.

After each bot/chat pair's own poll cycle within the loop (TGT-116),
this process writes a heartbeat (L<D2TG::Config/write_heartbeat>) to the
same C<.tira/> vault as the lock file, unconditionally - regardless of
whether a message arrived or an error occurred that pair. C<d2 tg.status>
reads its age to distinguish "still genuinely cycling" from "alive but
silently wedged", per a real 80+ minute incident where a poller held its
lock and stayed alive but produced no output and silently lost a
message. The write happens per pair, not once after the whole
C<for>-loop finishes, because a single slow voice transcription's own
retry ladder (L<D2TG::Transcribe>'s medium->small->base tiers, up to
~900s total) can by itself exceed a naive once-per-full-cycle
heartbeat's staleness threshold even while the poller is healthy - a gap
a Codex review caught.

After every poll cycle, C<D2TG::Download::prune_vault> (TGT-052) keeps
the attachment vault at or under a 100MB cap, deleting the oldest files
first once it's exceeded - cheap enough to run unconditionally (a
directory listing and some C<stat> calls, no network), so the vault
never grows unbounded over the skill's lifetime.

C<SIGTERM>/C<SIGINT> also call L<D2TG::Transcribe>'s C<kill_current>
(TGT-031), so a transcription in progress at shutdown time is killed
immediately rather than being waited out - previously, since Perl defers
signal handling until the current blocking syscall returns, Ctrl+C could
appear completely unresponsive for as long as a slow C<whisper> run took.

After every poll cycle (and only when not already shutting down), the
poller re-reads its own on-disk C<VERSION> (TGT-036) and compares it to
the version it started with. If C<dashboard skills install tg> has
installed a newer version in the meantime, it prints a notice, cleanly
disconnects L<D2TG::Store>'s DB handle, and re-execs itself in place
(same PID) - a fresh Perl interpreter then loads the newly-installed
C<.pm> files from disk, so an already-running poller picks up a new
release on its own within one poll cycle, with no manual restart and no
systemd/cron involved.

The SQLite handle is explicitly disconnected before C<exec> to avoid
leaking that file descriptor; other open descriptors (e.g. a live LWP
socket connection, if any) are not explicitly closed first, since C<exec>
happens right after a poll cycle completes with no request in flight.
Any such descriptor would be closed by the kernel once the re-exec'd
process no longer references it - a one-off, low-severity resource note
rather than a correctness issue, since this only happens once per
version change, not on every poll cycle.

The re-exec target is resolved via
L<D2TG::Config/resolve_self_exec_path>, not the literal C<$0> captured
at launch (TGT-094, a live production incident): if the install that
triggered this restart also renamed this very script (as TGT-093 did
for real, killing a live poller), C<$0> would point at a path that no
longer exists.

=cut
