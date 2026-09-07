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

sub extract_db_flag {
    my (@args) = @_;

    my $alias;
    my @rest;
    while (@args) {
        my $arg = shift @args;
        if ( $arg eq '--db' || $arg eq '-d' ) {
            $alias = shift @args;
        }
        else {
            push @rest, $arg;
        }
    }

    return ( $alias, @rest );
}

sub resolve_alias_dir {
    my (%args) = @_;

    my $alias = $args{alias} // $ENV{D2TG_DB};
    return undef unless defined $alias && length $alias;

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

=head2 attachments_dir(default_root => $path, base_dir => $path)

Resolves and returns the directory downloaded attachments (TGT-051)
should live in, creating it if missing. Mirrors C<state_db_path>'s own
resolution exactly: C<files/> under C<base_dir> if given, otherwise
C<files/> under the skill root (C<DEVELOPER_DASHBOARD_SKILL_ROOT> or
C<default_root>).

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

=head2 resolve_alias_dir(alias => $alias, paths => \%paths)

Resolves a Developer Dashboard path alias (TGT-051 - the left column of
C<d2 paths>) to its filesystem directory, for use as C<state_db_path>/
C<attachments_dir>'s C<base_dir>. C<alias> is optional and falls back to
C<$ENV{D2TG_DB}> when not given directly (an explicit C<alias> always
wins over the env var). Returns C<undef> - meaning "no override, use the
default resolution" - when neither is set. Dies with a clear message
(naming the unknown alias and pointing at C<d2 paths>) if an alias I<is>
given but isn't a recognized path. C<paths> is optional and defaults to
a live call into C<Developer::Dashboard>'s C<d2()-E<gt>paths>; tests
inject a plain hashref here instead, so this function - and every
caller of it - never needs a real Developer Dashboard environment to be
unit-tested.

=head2 skill_version(default_root => $path)

Reads and returns the C<VERSION=...> line from this skill's own
C<.env> (TGT-036), resolving the skill root the same way
C<state_db_path> does. Dies with a clear message if C<.env> can't be
read at all, or if it has no C<VERSION> line. C<cli/poller> uses this
to detect when a newer version has been installed while it is still
running, so it can restart itself.

=cut
