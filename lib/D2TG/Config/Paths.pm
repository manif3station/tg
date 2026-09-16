package D2TG::Config::Paths;

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use D2TG::OrDie;

# TGT-260: extracted out of D2TG::Config.pm (which had grown to 1131
# lines) - these functions resolve where every piece of this skill's
# state lives on disk (or under a Developer Dashboard alias/TIRA_HOME),
# the single largest cohesive cluster in that file. D2TG::Config keeps
# thin forwarding subs with the same names for every existing caller -
# no behavior change, just a smaller Config.pm.

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
# the 13 cli/*.pl scripts. TGT-269: the wrapper idiom itself moved into
# D2TG::OrDie::or_die (found duplicated a further 3 times across other
# modules) - this is now a one-line forwarder.
sub resolve_alias_dir_or_die {
    my (%args) = @_;
    return D2TG::OrDie::or_die( \&resolve_alias_dir, %args );
}

sub require_existing_base_dir {
    my ($base_dir) = @_;

    return $base_dir if -d $base_dir;

    die "Storage location '$base_dir' does not exist - refusing to start. "
      . "This resolves a --db/-d/D2TG_DB alias or a TIRA_HOME fallback to a "
      . "real, already-existing directory; it never creates one. Check the "
      . "value (typo?) or create the directory yourself first.\n";
}

# TGT-230: the eval/print-STDERR/exit(1) wrapper around
# require_existing_base_dir was duplicated byte-for-byte across 11
# cli/*.pl scripts. TGT-269: now a one-line forwarder onto
# D2TG::OrDie::or_die.
sub require_existing_base_dir_or_die {
    my ($base_dir) = @_;
    return D2TG::OrDie::or_die( \&require_existing_base_dir, $base_dir );
}

sub resolve_self_exec_path {
    my (%args) = @_;

    my $candidate = File::Spec->catfile( $args{bin_dir}, $args{basename} );

    return $candidate if -f $candidate;
    return $args{fallback};
}

sub _developer_dashboard_paths {
    require Developer::Dashboard;
    return Developer::Dashboard::d2()->paths;
}

1;

__END__

=head1 NAME

D2TG::Config::Paths - state/attachment/lock/heartbeat path resolution

=head1 SYNOPSIS

    my $db_path = D2TG::Config::Paths::state_db_path( base_dir => $dir );

=head1 DESCRIPTION

TGT-260: extracted out of D2TG::Config.pm (which had grown to 1131
lines) - this is the largest cohesive cluster in that file: everywhere
this skill's own state (message store, attachments, lock file,
heartbeat) or a caller-supplied Developer Dashboard alias/TIRA_HOME
gets resolved to a real directory on disk. D2TG::Config keeps thin
forwarding subs with the same names for every existing caller, so no
behavior changes.

=head1 FUNCTIONS

=head2 state_db_path(base_dir => $dir | default_root => $root)

Resolves the SQLite message-store path, creating its parent directory
if needed.

=head2 attachments_dir(base_dir => $dir | default_root => $root)

Resolves the attachments directory, creating it if needed.

=head2 lock_path(base_dir => $dir | default_root => $root)

Resolves the single-instance poller lock file path.

=head2 heartbeat_path(base_dir => $dir | default_root => $root)

Resolves the poller heartbeat file path.

=head2 write_heartbeat($path, renamer => $optional_coderef)

Atomically writes the current epoch time to C<$path> (temp file +
C<rename>, never a partial write).

=head2 heartbeat_age($path)

Returns seconds since the heartbeat was last written, or C<undef> if
the file is missing/unreadable/malformed.

=head2 resolve_alias_dir(alias => $a, tira_home => $t, paths => $p)

Resolves a C<--db>/C<-d>/C<D2TG_DB> alias (or a C<TIRA_HOME> fallback)
to a real directory. Dies if neither is set, or the alias is unknown.

=head2 resolve_alias_dir_or_die(%args)

L</resolve_alias_dir>, printing to STDERR and exiting 1 on failure
instead of propagating the die - a one-line forwarder onto the shared
L<D2TG::OrDie/or_die> helper (TGT-269).

=head2 require_existing_base_dir($base_dir)

Dies unless C<$base_dir> already exists - never creates one.

=head2 require_existing_base_dir_or_die($base_dir)

L</require_existing_base_dir>, printing to STDERR and exiting 1 on
failure instead of propagating the die - a one-line forwarder onto the
shared L<D2TG::OrDie/or_die> helper (TGT-269).

=head2 resolve_self_exec_path(bin_dir => $d, basename => $b, fallback => $f)

Returns C<$bin_dir/$basename> if it exists, otherwise C<$fallback>.

=cut
