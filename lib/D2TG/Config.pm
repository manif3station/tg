package D2TG::Config;

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);

sub token   { return $ENV{D2TG_TOKEN}; }
sub chat_id { return $ENV{D2TG_CHAT_ID}; }

sub masked_token {
    my ($token) = @_;

    return '(not set)' unless defined $token && length $token;
    return $token if length($token) < 8;

    return substr( $token, 0, 4 ) . '...' . substr( $token, -4 );
}

sub require_chat_id_or_warn {
    my $chat_id = chat_id();

    if ( !defined $chat_id || $chat_id eq '' ) {
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

sub state_db_path {
    my (%args) = @_;

    if ( defined $args{base_dir} ) {
        make_path( $args{base_dir} ) unless -d $args{base_dir};
        return File::Spec->catfile( $args{base_dir}, 'store.sqlite' );
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

    my $skill_root = defined $args{base_dir}
      ? $args{base_dir}
      : ( $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} // $args{default_root} // '.' );

    my $dir = File::Spec->catdir( $skill_root, 'files' );
    make_path($dir) unless -d $dir;

    return $dir;
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
    die "D2TG_DB (or --db/-d <alias>) is not set - refusing to start. "
      . "Run 'd2 paths' to see valid aliases.\n"
      unless defined $alias && length $alias;

    my $paths = $args{paths} || _developer_dashboard_paths();
    my $dir   = $paths->{$alias};

    die "Unknown --db/-d alias '$alias' - run 'd2 paths' to see valid aliases\n"
      unless defined $dir;

    return $dir;
}

sub _developer_dashboard_paths {
    require Developer::Dashboard;
    return Developer::Dashboard::d2()->paths;
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

=head2 masked_token($token)

Returns C<$token> masked to its first 4 and last 4 characters joined by
C<...> (TGT-045), for safe display (e.g. the poller's own startup line)
without printing a live credential in full. C<undef> or an empty string
returns C<(not set)>; a token shorter than 8 characters (too short to
usefully mask) is returned unchanged rather than crashing or producing a
confusing result.

=head2 require_chat_id_or_warn

Returns true if C<D2TG_CHAT_ID> is set to a non-empty value. Otherwise
prints a warning to C<STDERR> naming the missing variable and returns
false. Callers (e.g. the poller entrypoint) are expected to refuse to
start when this returns false, rather than falling back to a default.

=head2 state_db_path(default_root => $path, base_dir => $path)

Resolves and returns the path to this skill's SQLite state file. With no
C<base_dir>, this is C<state/store.sqlite> under the skill root
(resolved from C<DEVELOPER_DASHBOARD_SKILL_ROOT> if set, otherwise the
given C<default_root> - callers typically pass
C<File::Spec-E<gt>catdir($Bin, '..')> for this), matching the original
behavior exactly. With an explicit C<base_dir> (TGT-051, from a resolved
C<--db>/C<-d>/C<D2TG_DB> alias - see C<resolve_alias_dir>), the file is
C<store.sqlite> directly under C<base_dir>, no C<state/> subdirectory.
Creates whichever directory it resolves to if missing. All of
C<cli/poller>, C<cli/reply>, C<cli/approve>, C<cli/unread>,
C<cli/history> use this so the resolution logic exists in exactly one
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
resolution exactly: C<files/> under C<base_dir> if given, otherwise
C<files/> under the skill root (C<DEVELOPER_DASHBOARD_SKILL_ROOT> or
C<default_root>) - and, like C<state_db_path>, the C<base_dir>-omitted
branch is test-only as of TGT-059, for the same reason.

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
C<cli/reply>'s own C<--db> extraction, and C<cli/history>'s
C<--since>/C<--until> handling - one implementation instead of four,
so a fifth call site (or a fifth future flag) gets this guard for free
instead of needing its own copy.

=head2 extract_db_flag(@ARGV)

Parses C<--db <alias>> / C<-d <alias>> out of a raw argument list
(TGT-051), recognized anywhere in the list. Used as-is by
C<cli/poller>/C<cli/approve>/C<cli/unread>/C<cli/history>, none of which
take free-form text arguments that could collide with this flag's own
name, so a whole-list scan is safe for them. C<cli/reply> does I<not>
use this function - it has its own leading-position-only extraction
instead (see its own POD), for the same reason
C<D2TG::Reply::parse_cli_args>'s C<--reply-to-message-id> is
trailing-only (TGT-042): reply text passed as free-form words could
otherwise collide with the flag's own name. Returns C<($alias,
@remaining_args)> - C<$alias> is C<undef> if the flag wasn't given.

Dies with C<--db/-d requires a value> (TGT-071, a real live-reproduced
incident, same bug class as TGT-069/070) if the token immediately after
C<--db>/C<-d> is missing, empty, or itself looks like a flag (starts
with C<->) - a bare trailing C<--db>, or C<--db> immediately followed by
another real flag (e.g. C<cli/history --db --since 2026-01-01>, C<cli/reply
--db --bot TOKEN ...>, C<cli/history --db --chat_id>), would otherwise
silently swallow that flag's own name as the alias and fail later with a
misleading C<Unknown --db/-d alias '--since'>-style message instead of
naming the real problem. Every caller (C<cli/poller>/C<cli/approve>/
C<cli/unread>/C<cli/history>) wraps this call in C<eval { ... }>,
printing C<$@> to STDERR and exiting 1 on failure - the same pattern
already used around C<resolve_alias_dir>'s own die. C<cli/reply>'s
separate leading-position-only C<--db> extraction (see above) has the
identical validation added directly in its own loop, since it doesn't
call this function. A consequence (flagged in TGT-071's Codex review):
a Developer Dashboard path alias can no longer itself begin with C<->
- not a real-world constraint, since C<d2 paths> aliases are plain
names, not flag-like strings. The validation itself is now delegated to
L</shift_flag_value> (TGT-072), which also backs L</bot_groups>'s
C<--chat_id> handling and C<cli/history>'s C<--since>/C<--until>
handling - one implementation instead of four.

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

Dies with a clear message pointing at C<d2 paths> in two cases (TGT-059):
when neither an explicit C<alias> nor C<$ENV{D2TG_DB}> is given at all -
mandatory, matching C<D2TG_CHAT_ID>'s existing hard-guard pattern; the
owner's original request, which TGT-051's first shipped version missed
by silently returning C<undef> (falling back to the skill's own install
directory) in this exact case - or when an alias I<is> given but isn't a
recognized path (unchanged since TGT-051). There is no longer any input
that returns C<undef> - every C<d2 tg.*> command's C<eval { ... }>
wrapper around this call turns either die into a clean refusal (STDERR
message, exit 1) before any state is ever touched.

=head2 skill_version(default_root => $path)

Reads and returns the C<VERSION=...> line from this skill's own
C<.env> (TGT-036), resolving the skill root the same way
C<state_db_path> does. Dies with a clear message if C<.env> can't be
read at all, or if it has no C<VERSION> line. C<cli/poller> uses this
to detect when a newer version has been installed while it is still
running, so it can restart itself.

=cut
