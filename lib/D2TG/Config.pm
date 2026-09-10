package D2TG::Config;

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);

sub token      { return $ENV{D2TG_TOKEN}; }
sub chat_id    { return $ENV{D2TG_CHAT_ID}; }
sub owner_name { return $ENV{D2TG_OWNER}; }

sub masked_token {
    my ($token) = @_;

    return '(not set)' unless defined $token && length $token;

    # TGT-138: a token too short to mask usefully (first-4/last-4) used
    # to be returned raw - the exact opposite of what this function
    # exists to prevent. A Codex review caught that <= 8, not < 8, is
    # the correct boundary: an exactly-8-character token's first 4 and
    # last 4 characters are the whole string, so substr(...,0,4).'...'.
    # substr(...,-4) would show every character, just reformatted with
    # '...' in the middle - not masked at all. Real Telegram bot tokens
    # are always far longer than 8 characters, so this path is
    # unreachable in normal operation, but a masking function's one
    # edge case must never leak the full secret regardless.
    return '(short token, not shown)' if length($token) <= 8;

    return substr( $token, 0, 4 ) . '...' . substr( $token, -4 );
}

sub require_chat_id_or_warn {
    my $chat_id = chat_id();

    # TGT-155 (JOB-003 scheduled hourly bug hunt finding, widened after
    # a Codex review finding of its own): chat_id() returns
    # D2TG_CHAT_ID completely raw, with no trimming or validation - any
    # value that isn't Telegram's own canonical integer chat-id shape
    # (bare digits, or a leading '-' for a group/supergroup/channel)
    # previously passed this check as long as it wasn't undef or
    # exactly ''. A whitespace-only value (a copy-paste error, a shell
    # quoting mistake) was the first case found, but the same silent
    # lockout equally applies to any other non-canonical value (leading/
    # trailing whitespace around an otherwise-valid id, e.g. ' 12345 '
    # or "\t12345" - the first fix's own /^\s*$/ check missed exactly
    # this) - Telegram's real numeric chat_id can never string-eq match
    # a mangled one, so the real owner is locked out forever with zero
    # warning. Validates the full expected shape instead of merely
    # excluding known-bad shapes, so no other mangled-but-not-blank
    # variant can slip through the same gap again.
    if ( !defined $chat_id || $chat_id !~ /^-?\d+$/ ) {
        warn "D2TG_CHAT_ID is not set - refusing to start the poller.\n";
        return 0;
    }

    return 1;
}

sub skill_version {
    my (%args) = @_;

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';

    my $env_path = File::Spec->catfile( $skill_root, '.env' );

    open my $fh, '<', $env_path
      or die "D2TG::Config::skill_version: cannot read $env_path: $!\n";
    local $/;
    my $env = <$fh>;
    close $fh;

    my ($version) = $env =~ /^VERSION=(\S+)$/m;
    die "D2TG::Config::skill_version: no VERSION line found in $env_path\n"
      unless defined $version;

    return $version;
}

sub changes_summary {
    my (%args) = @_;

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';
    my $version = $args{version};

    my $changes_path = File::Spec->catfile( $skill_root, 'Changes' );
    open my $fh, '<', $changes_path or return undef;
    local $/;
    my $changes = <$fh>;
    close $fh;

    # Codex review findings (two rounds): bound the entry at the next
    # actual version header (e.g. "0.92  2026-09-09" - digits, dot,
    # digits, whitespace, an ISO date, end of line), not at any
    # unindented line, nor at any line merely starting with digits and
    # whitespace (a stray "1.2 notes..." prose line inside an entry
    # would otherwise still be mistaken for a header). A bare
    # "(?=\n\S|\z)" would truncate the entry early if it ever contained
    # an unindented continuation/prose line, potentially missing a real
    # bullet further down.
    return undef
      unless $changes =~ /^\Q$version\E\s+\S+\n(.*?)(?=^\d+\.\d+[ \t]+\d{4}-\d{2}-\d{2}[ \t]*$|\z)/ms;
    my $block = $1;

    my ($first_bullet_line) = $block =~ /^\s*-\s*(.+?)\s*$/m;
    return $first_bullet_line;
}

sub state_db_path {
    my (%args) = @_;

    if ( defined $args{base_dir} ) {
        my $vault_dir = File::Spec->catdir( $args{base_dir}, '.tira' );
        make_path($vault_dir) unless -d $vault_dir;
        return File::Spec->catfile( $vault_dir, 'telegram.messages.db' );
    }

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';

    my $state_dir = File::Spec->catdir( $skill_root, 'state' );
    make_path($state_dir) unless -d $state_dir;

    return File::Spec->catfile( $state_dir, 'store.sqlite' );
}

sub attachments_dir {
    my (%args) = @_;

    if ( defined $args{base_dir} ) {
        my $dir = File::Spec->catdir( $args{base_dir}, '.tira', 'attachments' );
        make_path($dir) unless -d $dir;
        return $dir;
    }

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} // $args{default_root} // '.';

    my $dir = File::Spec->catdir( $skill_root, 'files' );
    make_path($dir) unless -d $dir;

    return $dir;
}

sub lock_path {
    my (%args) = @_;

    if ( defined $args{base_dir} ) {
        my $vault_dir = File::Spec->catdir( $args{base_dir}, '.tira' );
        make_path($vault_dir) unless -d $vault_dir;
        return File::Spec->catfile( $vault_dir, 'telegram.pid' );
    }

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';

    my $state_dir = File::Spec->catdir( $skill_root, 'state' );
    make_path($state_dir) unless -d $state_dir;

    return File::Spec->catfile( $state_dir, 'poller.pid' );
}

sub heartbeat_path {
    my (%args) = @_;

    if ( defined $args{base_dir} ) {
        my $vault_dir = File::Spec->catdir( $args{base_dir}, '.tira' );
        make_path($vault_dir) unless -d $vault_dir;
        return File::Spec->catfile( $vault_dir, 'telegram.heartbeat' );
    }

    my $skill_root = $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}
      // $args{default_root}
      // '.';

    my $state_dir = File::Spec->catdir( $skill_root, 'state' );
    make_path($state_dir) unless -d $state_dir;

    return File::Spec->catfile( $state_dir, 'poller.heartbeat' );
}

sub write_heartbeat {
    my ( $path, %args ) = @_;

    # Codex review finding (TGT-116): opening the live path with '>'
    # truncates it before the new timestamp is written, so a concurrent
    # 'd2 tg.status' read - or a crash between truncate and write - could
    # see an empty file (misread as heartbeat: never) or permanently lose
    # the last valid timestamp. Write to a temp file in the same
    # directory, then rename() over the real path - rename is atomic on
    # the same filesystem, so a reader never observes a partial write.
    my $tmp_path = "$path.tmp.$$";
    my $renamer  = $args{renamer} || sub { return rename( $_[0], $_[1] ); };

    open my $fh, '>', $tmp_path
      or die "D2TG::Config::write_heartbeat: cannot write $tmp_path: $!\n";
    print {$fh} time()
      or die "D2TG::Config::write_heartbeat: cannot write $tmp_path: $!\n";
    close $fh
      or die "D2TG::Config::write_heartbeat: cannot close $tmp_path: $!\n";

    unless ( $renamer->( $tmp_path, $path ) ) {
        # TGT-139: a failed rename() must not leave the staging file
        # behind - every failed write attempt would otherwise add
        # another orphaned $path.tmp.$$ file to the state directory.
        # unlink is best-effort; $! is captured first since unlink
        # itself can clobber it before the die message reads it.
        my $rename_error = $!;
        unlink $tmp_path;
        die "D2TG::Config::write_heartbeat: cannot rename $tmp_path to $path: $rename_error\n";
    }

    return;
}

sub heartbeat_age {
    my ($path) = @_;

    open my $fh, '<', $path or return undef;
    my $written = <$fh>;
    close $fh;

    return undef unless defined $written && $written =~ /^\d+$/;

    return time() - $written;
}

sub shift_flag_value {
    my ( $args, $flag_label ) = @_;

    my $value = shift @$args;
    die "$flag_label requires a value\n"
      unless defined $value && $value ne '' && $value !~ /^--?[A-Za-z]/;

    return $value;
}

sub extract_db_flag {
    my (@args) = @_;

    my $alias;
    my @rest;
    while (@args) {
        my $arg = shift @args;
        if ( $arg eq '--db' || $arg eq '-d' ) {
            $alias = shift_flag_value( \@args, '--db/-d' );
        }
        else {
            push @rest, $arg;
        }
    }

    return ( $alias, @rest );
}

sub extract_db_flag_or_die {
    my (@args) = @_;

    my @result = eval { extract_db_flag(@args) };
    if ($@) {
        print STDERR $@;
        exit 1;
    }
    return @result;
}

sub bot_groups {
    my (%args) = @_;

    my @argv = @{ $args{argv} || [] };
    my $env_chat_id = exists $args{env_chat_id} ? $args{env_chat_id} : $ENV{D2TG_CHAT_ID};
    my $env_token   = exists $args{env_token}   ? $args{env_token}   : $ENV{D2TG_TOKEN};

    push @argv, '--chat_id', $env_chat_id if defined $env_chat_id && length $env_chat_id;
    push @argv, '--bot',     $env_token   if defined $env_token   && length $env_token;

    my @groups;
    my $current;
    my @rest;

    while (@argv) {
        my $arg = shift @argv;

        if ( $arg eq '--chat_id' ) {
            my $value = shift_flag_value( \@argv, '--chat_id' );
            $current = { chat_id => $value, bots => [] };
            push @groups, $current;
        }
        elsif ( $arg eq '--bot' ) {
            die "D2TG::Config::bot_groups: --bot given before any --chat_id\n"
              unless $current;
            my $token = shift_flag_value( \@argv, '--bot' );
            push @{ $current->{bots} }, $token;
        }
        else {
            push @rest, $arg;
        }
    }

    return ( \@groups, @rest );
}

sub resolve_alias_dir {
    my (%args) = @_;

    my $alias = $args{alias} // $ENV{D2TG_DB};

    if ( !defined $alias || !length $alias ) {
        my $tira_home = exists $args{tira_home} ? $args{tira_home} : $ENV{TIRA_HOME};

        if ( defined $tira_home && length $tira_home ) {

            # TGT-091 (live production incident): TIRA_HOME's real-world
            # value is a d2-paths alias name (e.g. "tira-zen"), not
            # necessarily a raw filesystem path - resolve it the same
            # way an explicit --db/-d/D2TG_DB alias would be, and only
            # fall back to treating it as a literal path if it doesn't
            # match any registered alias (preserving the original
            # TGT-081 behavior for a caller that really did set
            # TIRA_HOME to a raw absolute path).
            my $paths = $args{paths} || _developer_dashboard_paths();
            return $paths->{$tira_home} if defined $paths->{$tira_home};

            return $tira_home;
        }

        die "D2TG_DB (or --db/-d <alias>) is not set - refusing to start. "
          . "Run 'd2 paths' to see valid aliases.\n";
    }

    my $paths = $args{paths} || _developer_dashboard_paths();
    my $dir   = $paths->{$alias};

    die "Unknown --db/-d alias '$alias' - run 'd2 paths' to see valid aliases\n"
      unless defined $dir;

    return $dir;
}

# TGT-172: extracted after this exact eval/print-STDERR/exit(1) wrapper
# around resolve_alias_dir was found duplicated identically across 11 of
# the 13 cli/*.pl scripts - matches the established shift_flag_value
# (TGT-072) / _classify_store_error (TGT-167) / _format_forwarded_sender
# (TGT-170) / _validate_reply_to_message_id (TGT-171) precedent for this
# shape of duplication.
sub resolve_alias_dir_or_die {
    my (%args) = @_;

    my $base_dir = eval { resolve_alias_dir(%args) };
    if ($@) {
        print STDERR $@;
        exit 1;
    }
    return $base_dir;
}

sub require_existing_base_dir {
    my ($base_dir) = @_;

    return $base_dir if -d $base_dir;

    die "Storage location '$base_dir' does not exist - refusing to start. "
      . "This resolves a --db/-d/D2TG_DB alias or a TIRA_HOME fallback to a "
      . "real, already-existing directory; it never creates one. Check the "
      . "value (typo?) or create the directory yourself first.\n";
}

sub resolve_self_exec_path {
    my (%args) = @_;

    my $candidate = File::Spec->catfile( $args{bin_dir}, $args{basename} );

    return $candidate if -f $candidate;
    return $args{fallback};
}

sub is_transient_error {
    my ($error) = @_;

    return 1 if $error =~ /timed out/i;
    return 1 if $error =~ /status 5\d\d/;

    # TGT-160 (found via a scheduled hourly bug hunt): Telegram's own
    # Bot API documents 429 ("Too Many Requests") as a designed,
    # expected, retryable rate-limit condition (a response body
    # containing parameters.retry_after) - matches the same "not
    # actually wrong" treatment 5xx/timeout already get. Deliberately
    # does not read parameters.retry_after here - that would require
    # parsing the response body, out of scope for this narrow
    # classification fix.
    return 1 if $error =~ /status 429\b/;

    return 0;
}

sub is_expired_file_error {
    my ($error) = @_;

    # Codex review finding: Telegram's own "file is temporarily
    # unavailable" wording describes a condition that CAN still succeed
    # on a later retry (a real transient server-side hiccup, the same
    # shape as any other getFile failure) - it must not be presented to
    # an operator as permanently unrecoverable. Only "no longer
    # available" and "wrong file_id" are Telegram's genuinely-permanent
    # shapes (an expired or invalid file_id can never resolve).
    return 0 unless defined $error;
    return 1 if $error =~ /file is no longer available/i;
    return 1 if $error =~ /wrong file_id/i;
    return 0;
}

sub _developer_dashboard_paths {
    require Developer::Dashboard;
    return Developer::Dashboard::d2()->paths;
}

# TGT-173: extracted after this exact SIGALRM-based hard-timeout wrapper
# was found to have identical control flow across D2TG::Telegram and
# D2TG::Download, differing only in how each caller constructed its own
# timeout-message prefix - matches the established shift_flag_value
# (TGT-072) / _classify_store_error (TGT-167) / _format_forwarded_sender
# (TGT-170) / _validate_reply_to_message_id (TGT-171) /
# resolve_alias_dir_or_die (TGT-172) precedent for this shape of
# duplication, this time cross-package. $label is the caller's own
# already-composed die-message prefix (e.g. "D2TG::Telegram sendMessage"
# or "D2TG::Download::download_file"), preserved verbatim so each call
# site's exact die wording is unchanged.
sub _with_hard_timeout {
    my ( $seconds, $label, $coderef ) = @_;

    my $result;
    eval {
        local $SIG{ALRM} = sub { die "$label: request timed out after ${seconds}s\n" };
        alarm($seconds);
        $result = $coderef->();
        alarm(0);
    };
    my $error = $@;
    alarm(0);
    die $error if $error;

    return $result;
}

1;

=head1 NAME

D2TG::Config - environment-driven configuration for the tg skill

=head1 SYNOPSIS

    use D2TG::Config;

    my $token   = D2TG::Config::token();
    my $chat_id = D2TG::Config::chat_id();

    exit 1 unless D2TG::Config::require_chat_id_or_warn();

=head1 DESCRIPTION

Reads the two environment variables this skill is configured by. There is
no config file and no hardcoded fallback - C<D2TG_TOKEN> and
C<D2TG_CHAT_ID> are read from C<%ENV> only.

=head1 FUNCTIONS

=head2 token

Returns the value of C<D2TG_TOKEN>, or C<undef> if unset.

=head2 chat_id

Returns the value of C<D2TG_CHAT_ID>, or C<undef> if unset.

=head2 owner_name

Returns the value of C<D2TG_OWNER> (TGT-079, a live user request), or
C<undef> if unset. Used by C<D2TG::Poller>'s display-name substitution:
a message from the L</chat_id> chat shows this name instead of the
sender's raw Telegram username, when set. Purely a display preference -
has no effect on access control, which continues to key everything on
the numeric chat id.

=head2 masked_token($token)

Returns C<$token> masked to its first 4 and last 4 characters joined by
C<...> (TGT-045), for safe display (e.g. the poller's own startup line)
without printing a live credential in full. C<undef> or an empty string
returns C<(not set)>; a token 8 characters or shorter (too short to
usefully mask that way - at exactly 8 characters, "first 4 and last 4"
is the whole string) returns the fixed placeholder
C<(short token, not shown)> (TGT-138) - never the raw value, since a
masking function's one edge case must never be the one that leaks the
full secret. Real Telegram bot tokens are always far longer than 8
characters, so this branch is not reachable in normal operation.

=head2 require_chat_id_or_warn

Returns true if C<D2TG_CHAT_ID> matches Telegram's own canonical chat-id
shape (bare digits, or a leading C<-> for a group/supergroup/channel).
Otherwise prints a warning to C<STDERR> naming the missing variable and
returns false. Callers (e.g. the poller entrypoint) are expected to
refuse to start when this returns false, rather than falling back to a
default.

TGT-155 (JOB-003 scheduled hourly bug hunt finding, widened after a
Codex review finding of its own): L</chat_id> returns the env var
completely raw, with no trimming or validation - any value that wasn't
Telegram's own canonical integer shape previously passed this check as
long as it wasn't C<undef> or exactly C<''>. A whitespace-only value (a
copy-paste error, a shell quoting mistake) was the first case found, but
the identical silent lockout equally applies to any other non-canonical
value - leading/trailing whitespace around an otherwise-valid id (e.g.
C<' 12345 '>), which the first, narrower whitespace-only check still
missed. Telegram's real numeric chat_id can never string-eq match a
mangled one, so the real owner is locked out forever with zero warning.
Validates the full expected shape instead of merely excluding
known-bad shapes, so no other mangled-but-not-blank variant can slip
through the same gap again - deliberately refuses rather than
auto-trimming and proceeding with a stripped value, since silently
continuing on a mangled value risks masking a different, more confusing
partial-corruption case; the safe behavior is the same hard refusal
already used for the missing case.

=head2 state_db_path(default_root => $path, base_dir => $path)

Resolves and returns the path to this skill's SQLite state file. With no
C<base_dir>, this is C<state/store.sqlite> under the skill root
(resolved from C<DEVELOPER_DASHBOARD_SKILL_ROOT> if set, otherwise the
given C<default_root> - callers typically pass
C<File::Spec-E<gt>catdir($Bin, '..')> for this), matching the original
behavior exactly. With an explicit C<base_dir> (TGT-051, from a resolved
C<--db>/C<-d>/C<D2TG_DB> alias, or a C<TIRA_HOME> fallback - see
C<resolve_alias_dir>), the file is C<telegram.messages.db> under a
C<.tira/> subdirectory of C<base_dir> (TGT-081, a live user request -
was C<store.sqlite> directly under C<base_dir>, no subdirectory, before
this ticket). Creates whichever directory it resolves to if missing. All of
C<cli/poller.pl>, C<cli/reply.pl>, C<cli/approve.pl>, C<cli/unread.pl>,
C<cli/history.pl> use this so the resolution logic exists in exactly one
place.

Since TGT-059 made C<resolve_alias_dir> always either die or return a
defined directory, every one of those five callers now always supplies
C<base_dir> - none can reach this function without one anymore. The
C<base_dir>-omitted branch above is kept only because C<D2TG::Config>
itself is still unit-tested by calling C<state_db_path> directly with no
C<base_dir> (see C<t/40-db-alias-resolution.t>); no shipped C<d2 tg.*>
invocation can trigger it.

=head2 attachments_dir(default_root => $path, base_dir => $path)

Resolves and returns the directory downloaded attachments (TGT-051)
should live in, creating it if missing. Mirrors C<state_db_path>'s own
resolution exactly: C<.tira/attachments> under C<base_dir> if given
(TGT-081 - was C<files/> directly under C<base_dir> before this
ticket), otherwise C<files/> under the skill root
(C<DEVELOPER_DASHBOARD_SKILL_ROOT> or C<default_root>) - and, like
C<state_db_path>, the C<base_dir>-omitted branch is test-only as of
TGT-059, for the same reason.

=head2 lock_path(default_root => $path, base_dir => $path)

Resolves and returns the path to C<cli/poller.pl>'s single-instance PID
lock file (L<D2TG::Lock>), creating whichever directory it resolves to
if missing. Mirrors C<state_db_path>/C<attachments_dir>'s own
resolution exactly: with an explicit C<base_dir>, the file is
C<telegram.pid> under a C<.tira/> subdirectory of C<base_dir> (TGT-087,
a live user request following on from TGT-081's own vault nesting - was
C<poller.pid> directly under C<base_dir>, no subdirectory, before this
ticket); with no C<base_dir>, C<state/poller.pid> under the skill root
(C<DEVELOPER_DASHBOARD_SKILL_ROOT> or the given C<default_root>). As
with the other two resolvers, the C<base_dir>-omitted branch is
test-only as of TGT-059 - C<cli/poller.pl> always supplies C<base_dir> in
practice.

=head2 shift_flag_value($args_arrayref, $flag_label)

Shared helper (TGT-072) extracted after TGT-068/069/070/071
independently rediscovered and hand-patched the same bug four times:
shifts the next value off C<$args_arrayref> and dies with
C<"$flag_label requires a value\n"> unless it's defined, non-empty, and
doesn't itself look like a I<flag> - one or two leading dashes followed
by a letter (C<--since>, C<-d>), not merely anything starting with a
dash. A Codex review during TGT-072 caught that the original, simpler
C<!~ /^-/> check would have rejected a legitimate negative Telegram
group/supergroup chat id (e.g. C<-1001234567890>, always negative for
those chat types) passed to C<--chat_id>, which would have been a real
regression despite passing every then-existing test (none exercised a
negative chat id). C<-100...> and similar numeric-negative values pass
through fine; only a dash immediately followed by a letter is rejected.
Used by L</extract_db_flag>, L</bot_groups>'s C<--chat_id> handling,
C<cli/reply.pl>'s own C<--db> extraction, and C<cli/history.pl>'s
C<--since>/C<--until> handling - one implementation instead of four,
so a fifth call site (or a fifth future flag) gets this guard for free
instead of needing its own copy.

=head2 extract_db_flag(@ARGV)

Parses C<--db <alias>> / C<-d <alias>> out of a raw argument list
(TGT-051), recognized anywhere in the list. Since TGT-177, every
C<cli/*.pl> script that uses this whole-list scan (10 total) goes
through L</extract_db_flag_or_die> rather than calling this function
directly - see that function's own POD below for the full list. Most
of those take no free-form text arguments that could collide with this
flag's own name, so a whole-list scan is unambiguously safe for them;
C<cli/send.pl> is the one exception (its own C<--caption> is free-form
text) and accepts a narrow, already-documented ambiguity in its own
POD/comments as a deliberate trade-off for staying consistent with
every other script here, rather than getting its own bespoke
position-aware extraction. C<cli/reply.pl> does I<not> use this
function - it has its own leading-position-only
extraction
instead (see its own POD), for the same reason
C<D2TG::Reply::parse_cli_args>'s C<--reply-to-message-id> is
trailing-only (TGT-042): reply text passed as free-form words could
otherwise collide with the flag's own name. Returns C<($alias,
@remaining_args)> - C<$alias> is C<undef> if the flag wasn't given.

Dies with C<--db/-d requires a value> (TGT-071, a real live-reproduced
incident, same bug class as TGT-069/070) if the token immediately after
C<--db>/C<-d> is missing, empty, or itself looks like a flag (starts
with C<->) - a bare trailing C<--db>, or C<--db> immediately followed by
another real flag (e.g. C<cli/history.pl --db --since 2026-01-01>, C<cli/reply.pl
--db --bot TOKEN ...>, C<cli/history.pl --db --chat_id>), would otherwise
silently swallow that flag's own name as the alias and fail later with a
misleading C<Unknown --db/-d alias '--since'>-style message instead of
naming the real problem. Since TGT-177, every CLI caller except C<cli/reply.pl> goes through
L</extract_db_flag_or_die> instead of wrapping this call in its own
C<eval { ... }> - see that function's own POD below. C<cli/reply.pl>'s
separate leading-position-only C<--db> extraction (see above) has the
identical validation added directly in its own loop, since it doesn't
call this function. A consequence (flagged in TGT-071's Codex review):
a Developer Dashboard path alias can no longer itself begin with C<->
- not a real-world constraint, since C<d2 paths> aliases are plain
names, not flag-like strings. The validation itself is now delegated to
L</shift_flag_value> (TGT-072), which also backs L</bot_groups>'s
C<--chat_id> handling and C<cli/history.pl>'s C<--since>/C<--until>
handling - one implementation instead of four.

=head2 extract_db_flag_or_die(@ARGV)

TGT-177 (found via a scheduled improvement hunt): wraps L</extract_db_flag>
in the identical C<eval { ... }; if ($@) { print STDERR $@; exit 1; }>
pattern 10 C<cli/*.pl> scripts (C<approve>/C<attachment>/C<history>/
C<poller>/C<retry-download>/C<send>/C<status>/C<text-only-replies>/
C<unread>/C<whoami>) had each independently duplicated - matching
L</resolve_alias_dir_or_die>'s own identical TGT-172 extraction of the
same shape for C<resolve_alias_dir>. Pure refactor: same exit code,
same STDERR text (byte-for-byte, not just the same wording), same
return shape C<($alias, @remaining_args)> - no caller's own observable
behavior changes. C<cli/reply.pl> is not among the callers, since it
uses its own separate leading-position-only C<--db> extraction (see
L</extract_db_flag>'s own POD above) rather than this function.

=head2 bot_groups(argv => \@argv, env_chat_id => $id, env_token => $token)

Parses repeatable C<--chat_id <id>>/C<--bot <token>> pairs (TGT-049)
into an ordered list of groups: each C<--chat_id> starts a new group,
and each C<--bot> attaches to the most recently declared C<--chat_id>.
Returns C<(\@groups, @rest)> - C<@groups> is a list of
C<{ chat_id => ..., bots => [...] }> hashrefs in declaration order;
C<@rest> is every argument that wasn't part of a C<--chat_id>/C<--bot>
pair, unconsumed and in order, for the caller to keep parsing.

C<env_chat_id>/C<env_token> default to C<$ENV{D2TG_CHAT_ID}>/
C<$ENV{D2TG_TOKEN}> (pass explicit values, including C<undef>, to
override for testing). Neither is special-cased: whichever is defined
and non-empty is appended to C<argv> as an ordinary trailing
C<--chat_id>/C<--bot> pair I<before> parsing, so the exact same grouping
algorithm handles every case without a separate merge path:

=over 4

=item * Only env vars set, no CLI args at all (today's only mode): the
appended stream is exactly one C<--chat_id>/C<--bot> pair, producing a
single group - byte-for-byte equivalent to today's single-bot behavior.

=item * C<env_token> set alone, with existing CLI-declared groups: only
C<--bot $token> is appended, with no preceding C<--chat_id>, so it
attaches to the I<last> already-open group.

=item * Both env vars set, with existing CLI-declared groups: C<--chat_id
$env_chat_id --bot $env_token> is appended as its own new, separate
group.

=back

Dies if a C<--bot> is encountered (from either C<argv> or the appended
env pair) with no C<--chat_id> having been declared yet. Also dies
(TGT-074, same bug class as TGT-069/071/072's C<--chat_id>/C<--db>
fixes) if C<--bot>'s own shifted value is missing or itself flag-like -
a bare trailing C<--bot>, or C<--bot> immediately followed by another
flag, would otherwise silently push C<undef> (or that flag's own name)
into the group's C<bots> list instead of erroring. Delegated to
L</shift_flag_value>, same as C<--chat_id>'s own validation above.

Dies (TGT-069, a real live-reproduced incident: a bare trailing
C<--chat_id> reached D2TG::Store's SQL bind as an opaque
C<DBD::SQLite::db do failed: datatype mismatch>, several layers away
from the actual mistake) if a C<--chat_id> has no usable value following
it - either nothing at all, or another recognized flag token
(C<--chat_id>/C<--bot>). The latter case matters specifically because of
the env-merge behavior above: if C<env_token> is set, it appends its own
C<--bot $token> pair to C<argv> I<before> parsing, so a bare trailing
C<--chat_id> in the caller's own args is never actually the last element
of the combined stream - a naive "is anything left" check would let
C<--bot> itself be consumed as the chat_id value instead of failing.
This validation is now delegated to L</shift_flag_value> (TGT-072),
which checks generically for any flag-like value (starts with C<->)
rather than only the two specific sibling flag names.

=head2 resolve_alias_dir(alias => $alias, paths => \%paths)

Resolves a Developer Dashboard path alias (TGT-051 - the left column of
C<d2 paths>) to its filesystem directory, for use as C<state_db_path>/
C<attachments_dir>'s C<base_dir>. C<alias> is optional and falls back to
C<$ENV{D2TG_DB}> when not given directly (an explicit C<alias> always
wins over the env var). C<paths> is optional and defaults to a live call
into C<Developer::Dashboard>'s C<d2()-E<gt>paths>; tests inject a plain
hashref here instead, so this function - and every caller of it - never
needs a real Developer Dashboard environment to be unit-tested.

When neither an explicit C<alias> nor C<$ENV{D2TG_DB}> is given at all,
falls back to C<$ENV{TIRA_HOME}> as the base_dir (TGT-081, a live user
request) instead of refusing. As of TGT-091 (a live production
incident: C<TIRA_HOME=tira-zen> - a real, registered C<d2 paths> alias
in the owner's own environment - was being treated as a literal
filesystem path and refused), C<TIRA_HOME>'s value is resolved the same
way an explicit C<alias> would be: looked up in C<paths> first, and
only used directly as a literal filesystem path if it doesn't match any
registered alias there. This preserves the original TGT-081 behavior
for a caller that really did set C<TIRA_HOME> to a raw absolute path,
while correctly resolving the (apparently more common in practice)
case where it names an alias instead. Pass C<tira_home> explicitly to
override C<$ENV{TIRA_HOME}> for testing, same pattern as
C<alias>/C<paths>. Only consulted when no alias was given at all - an
explicit C<alias> or C<D2TG_DB> always takes priority, and an unknown
alias still refuses exactly as before, never falling through to
C<TIRA_HOME>.

Dies with a clear message pointing at C<d2 paths> in two cases (TGT-059):
when neither an explicit C<alias> nor C<$ENV{D2TG_DB}> is given at all
AND C<TIRA_HOME> isn't set either - mandatory, matching
C<D2TG_CHAT_ID>'s existing hard-guard pattern; the owner's original
request, which TGT-051's first shipped version missed by silently
returning C<undef> (falling back to the skill's own install directory)
in this exact case - or when an alias I<is> given but isn't a
recognized path (unchanged since TGT-051). There is no longer any input
that returns C<undef> - each affected command turns either die into a
clean refusal (STDERR message, exit 1) before any state is ever
touched, via the shared L</resolve_alias_dir_or_die> wrapper (TGT-172,
11 of the 13 C<cli/*.pl> scripts) rather than each repeating that
C<eval { ... }> pattern inline.

Note that C<resolve_alias_dir> itself never checks whether the
directory it returns actually exists - see L</require_existing_base_dir>
below, which every C<cli/*> script calls immediately afterward to close
that gap (TGT-090).

=head2 resolve_alias_dir_or_die(alias => $alias, paths => \%paths)

TGT-172 (found via a scheduled improvement hunt): a thin wrapper around
L</resolve_alias_dir> that catches its die, prints the message to
STDERR, and exits 1 - the exact eval/print-STDERR/exit(1) pattern 11 of
the 13 C<cli/*.pl> scripts had each independently duplicated after
calling C<resolve_alias_dir> directly. Returns the resolved base_dir on
success, same as C<resolve_alias_dir>; never returns on failure. A pure
extraction - no behavior change at any of the 11 call sites.

=head2 require_existing_base_dir($base_dir)

Dies with a clear message naming C<$base_dir> if it is not already a
real, existing directory; otherwise returns C<$base_dir> unchanged
(TGT-090, a live user request + live reproduction). Every C<cli/*>
script calls this immediately after L</resolve_alias_dir> returns, so a
resolved base directory - whether a C<--db>/C<-d>/C<D2TG_DB> alias's
real path or a C<TIRA_HOME> fallback - is always confirmed to already
exist before anything is written under it. Before this existed,
C<TIRA_HOME>'s value was used completely unvalidated, and
C<state_db_path>/C<attachments_dir>/C<lock_path>'s own C<make_path>
calls on the C<.tira/> subdirectory would silently create the entire
tree - including a C<TIRA_HOME> base directory that had never actually
existed. Reproduced live: C<TIRA_HOME=foobar> made C<d2 tg.unread>
silently C<mkdir -p ./foobar/.tira/> and create
C<telegram.messages.db> inside it. This function does not affect the
C<.tira/> subdirectory itself - that is still created as normal once
C<$base_dir> is confirmed real; only the base directory itself must
pre-exist.

=head2 skill_version(default_root => $path)

Reads and returns the C<VERSION=...> line from this skill's own
C<.env> (TGT-036), resolving the skill root the same way
C<state_db_path> does. Dies with a clear message if C<.env> can't be
read at all, or if it has no C<VERSION> line. C<cli/poller.pl> uses this
to detect when a newer version has been installed while it is still
running, so it can restart itself.

=head2 changes_summary(version => $version, default_root => $path)

Returns the first bullet line of the given C<$version>'s own entry in
this skill's installed C<Changes> file (resolving the skill root the
same way L</skill_version> does), or C<undef> if C<Changes> can't be
read at all or has no entry for that version (TGT-112, user-supplied
live-experienced feedback: the version-bump restart notice named the
old/new version numbers but not what actually changed). A multi-line
bullet is truncated to its first physical line only - a short summary,
not a full reflow. C<cli/poller.pl>'s version-change restart notice
uses this to make itself self-describing without a separate lookup.

=head2 resolve_self_exec_path(bin_dir => $dir, basename => $name, fallback => $path)

Returns C<catfile($bin_dir, $basename)> if that file exists on disk,
otherwise returns C<$fallback> unchanged (TGT-094, a live production
incident). C<cli/poller.pl>'s version-change restart (see
L</skill_version>) uses this instead of blindly C<exec()>ing the literal
C<$0> path captured at process launch: C<$0> is fixed once at startup, so
if an install renames the running poller's own entrypoint file while it
is still up (as TGT-093 did for real, killing a live poller with C<Can't
open perl script ... No such file or directory>), C<$0> points at a path
that no longer exists. C<$Bin> (from C<FindBin>), by contrast, only
depends on the script's I<directory>, which a filename-only rename
doesn't change - re-checking there for the known current basename
(C<poller.pl>) finds the live file regardless of what C<$0> says,
falling back to C<$0> only if that lookup itself fails.

=head2 heartbeat_path(default_root => $path, base_dir => $path)

Mirrors L</lock_path>'s own resolution exactly (TGT-116): given a
resolved C<base_dir>, returns C<base_dir/.tira/telegram.heartbeat>;
given no C<base_dir> at all, falls back to
C<default_root/state/poller.heartbeat> (or C<$ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}>
in place of C<default_root> when set), the same two-branch shape
L</lock_path> itself uses for C<telegram.pid>/C<poller.pid>.

=head2 write_heartbeat($path, renamer => \&coderef)

Writes the current epoch time to C<$path>, atomically: writes to a temp
file (C<$path.tmp.$$>) in the same directory, then C<rename>s it over
C<$path>. A Codex review caught that the original implementation opened
C<$path> directly with C<< '>' >>, truncating it before the new
timestamp was written - a concurrent L</heartbeat_age> read (from C<d2
tg.status>) or a crash between truncate and write could see an empty
file (misread as C<never>) or permanently lose the last valid
timestamp. C<rename> on the same filesystem is atomic, so a reader never
observes a partial write. Called by C<cli/poller.pl> after each bot/chat
pair's own poll cycle completes, not once per full multi-pair cycle - a
single voice transcription's retry ladder alone (L<D2TG::Transcribe>'s
medium->small->base tiers, 300s each) can take up to ~900s, so writing
only once per full cycle could report a healthy, actively-transcribing
poller as stale.

If C<rename> itself fails (TGT-139), the staging temp file is unlinked
(best-effort) before dying - previously a failed rename left C<$tmp_path>
behind, and every failed write attempt (e.g. a persistently read-only
state directory) would add another orphaned file to it. C<renamer> is an
optional coderef (mirroring L<D2TG::TTS/synthesize_to_file>'s own
C<renamer> injection point) taking C<($tmp_path, $path)> and returning
true on success; it defaults to a plain C<rename> call and exists so
callers (tests) can inject a fake failure instead of needing a real
unwritable filesystem.

=head2 heartbeat_age($path)

Returns the number of seconds since C<$path> was last written via
L</write_heartbeat>, or C<undef> if the file doesn't exist or doesn't
contain a bare integer timestamp. C<cli/status.pl> flags this stale
past a threshold derived from L<D2TG::Transcribe>'s own
C<$TIMEOUT_CEILING> and C<@MODEL_TIERS> constants (multiplied together,
plus a safety margin - currently 14400 seconds/4h, TGT-147 - not a
fixed literal, so it can never silently drift out of sync with the
transcription timeout it's meant to stay safely above again), kept
safely above the worst-case time a single
bot/chat pair's own poll cycle can legitimately take.

=head2 is_expired_file_error($error)

Returns true if C<$error> looks like Telegram's own shape for a
C<getFile> call against a file_id that can never resolve - matches
C</file is no longer available/i> or C</wrong file_id/i>, the
description text L<D2TG::Telegram>'s C<_call> forwards verbatim from a
failed Bot API response - false otherwise (TGT-104). C<cli/retry-download.pl>
uses this to give a retry against a permanently-gone handle a specific,
actionable message instead of the same generic download-failure text a
fresh, still-recoverable failure gets.

Deliberately does NOT match C<"file is temporarily unavailable"> (a
Codex review caught an earlier draft treating it as permanent) - that
wording describes a real transient condition that can still succeed on
a later retry, the same shape as any other C<getFile> failure; labeling
it unrecoverable would tell an operator to give up on something that
might well work again.

=head2 _with_hard_timeout($seconds, $label, \&coderef)

TGT-173 (found via a scheduled improvement hunt): a shared
SIGALRM-based hard-timeout wrapper, extracted after L<D2TG::Telegram>
(TGT-044) and L<D2TG::Download> (TGT-126) each independently
implemented the identical control flow - runs C<&coderef> under
C<alarm($seconds)>, so a C<SIGALRM> forcibly interrupts it (including a
blocking syscall like C<connect()>) if it hasn't returned within
C<$seconds>, more reliable than C<LWP::UserAgent>'s own C<timeout>
across every phase a request can get stuck in. On timeout, dies with
C<"$label: request timed out after ${seconds}s"> - C<$label> is the
caller's own already-composed die-message prefix (e.g. C<"D2TG::Telegram
sendMessage"> or C<"D2TG::Download::download_file">), passed through
verbatim so each call site's exact pre-extraction die wording is
preserved. C<alarm(0)> is always called before returning or
re-throwing, whether the call succeeded, failed, or timed out, so no
alarm is ever left pending.

=head2 is_transient_error($error)

Returns true if C<$error> looks like a transient failure - matches
C</timed out/i>, C</status 5\d\d/>, or C</status 429\b/>, the same
shapes L<D2TG::Telegram>'s own C<die> messages already use for a
network timeout, a 5xx response, or Telegram's own documented rate-
limit signal - false otherwise (TGT-097, widened by TGT-160). A shared
predicate: L<D2TG::Reply/format_send_error> (TGT-096) uses it to decide
whether a failed C<d2 tg.reply> should tell the calling agent to retry;
C<D2TG::Poller::run_once_safe> (TGT-097) uses it to decide whether a
poll-cycle failure is worth printing at all - a transient one retries
completely silently, since the retry loop already recovers on its own
and each printed occurrence was reaching the project's
C<tira.policy.bridge> as pure noise.

TGT-160 (found via a scheduled hourly bug hunt): a C<429> ("Too Many
Requests") response is Telegram's own designed, expected, retryable
rate-limit condition - a response body containing
C<parameters.retry_after> - not a genuine application error, even
though 429 remains an HTTP error status. It was previously
misclassified as non-transient and logged loudly as a genuine
C<POLL ERROR> on every routine flood-control response. Deliberately
does not read or honor C<parameters.retry_after> here - that would
require parsing the response body, out of scope for this narrow
classification fix; C<run_once_safe>'s own retry/backoff timing is
unchanged, only the loud-vs-silent logging decision changes.

=cut
