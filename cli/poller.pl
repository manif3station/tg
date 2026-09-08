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

# Multi-bot/multi-chat support (TGT-049): peek whether the CLI declared
# any --chat_id groups BEFORE consuming them, so the original single-var
# startup guard (exact message, for exact backward compatibility) only
# fires for the plain env-var-only case - CLI-declared groups supply
# their own chat ids independently of D2TG_CHAT_ID.
my $has_cli_groups = grep { $_ eq '--chat_id' } @ARGV;
exit 1 if !$has_cli_groups && !D2TG::Config::require_chat_id_or_warn();

my ( $groups, @leftover ) = D2TG::Config::bot_groups( argv => [@ARGV] );
@ARGV = @leftover;

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

=head1 DESCRIPTION

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
