use 5.010;
use strict;
use warnings;

package MongoDBx::Queue;

# ABSTRACT: A message queue implemented with MongoDB
our $VERSION = '1.001'; # VERSION

use Moose 2;
use MooseX::Types::Moose qw/:all/;
use MooseX::AttributeShortcuts;

use MongoDB 0.702 ();
use Tie::IxHash;
use boolean;
use namespace::autoclean;

my $ID       = '_id';
my $RESERVED = '_r';
my $PRIORITY = '_p';

with 'MooseX::Role::Logger', 'MooseX::Role::MongoDB' => { -version => 0.003 };

#--------------------------------------------------------------------------#
# Public attributes
#--------------------------------------------------------------------------#


has database_name => (
    is      => 'ro',
    isa     => Str,
    default => 'test',
);


has client_options => (
    is      => 'ro',
    isa     => HashRef,
    default => sub { {} },
);


has collection_name => (
    is      => 'ro',
    isa     => Str,
    default => 'queue',
);


has safe => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

sub _build__mongo_default_database { $_[0]->database_name }
sub _build__mongo_client_options   { $_[0]->client_options }

sub BUILD {
    my ($self) = @_;
    # ensure index on PRIORITY in the same order we use for reserving
    $self->mongo_collection( $self->collection_name )
      ->ensure_index( [ $PRIORITY => 1 ] );
}

#--------------------------------------------------------------------------#
# Public methods
#--------------------------------------------------------------------------#


sub add_task {
    my ( $self, $data, $opts ) = @_;

    $self->mongo_collection( $self->collection_name )
      ->insert( { %$data, $PRIORITY => $opts->{priority} // time(), },
        { safe => $self->safe, } );
}


sub reserve_task {
    my ( $self, $opts ) = @_;

    my $now    = time();
    my $result = $self->mongo_database->run_command(
        [
            findAndModify => $self->collection_name,
            query         => {
                $PRIORITY => { '$lte' => $opts->{max_priority} // $now },
                $RESERVED => { '$exists' => boolean::false },
            },
            sort => { $PRIORITY => 1 },
            update => { '$set' => { $RESERVED => $now } },
        ]
    );

    # XXX check get_last_error? -- xdg, 2012-08-29
    if ( ref $result ) {
        return $result->{value}; # could be undef if not found
    }
    else {
        die "MongoDB error: $result"; # XXX docs unclear, but imply string error
    }
}


sub reschedule_task {
    my ( $self, $task, $opts ) = @_;
    $self->mongo_collection( $self->collection_name )->update(
        { $ID => $task->{$ID} },
        {
            '$unset' => { $RESERVED => 0 },
            '$set'   => { $PRIORITY => $opts->{priority} // $task->{$PRIORITY} },
        },
        { safe => $self->safe }
    );
}


sub remove_task {
    my ( $self, $task ) = @_;
    $self->mongo_collection( $self->collection_name )->remove( { $ID => $task->{$ID} } );
}


sub apply_timeout {
    my ( $self, $timeout ) = @_;
    $timeout //= 120;
    my $cutoff = time() - $timeout;
    $self->mongo_collection( $self->collection_name )->update(
        { $RESERVED => { '$lt'     => $cutoff } },
        { '$unset'  => { $RESERVED => 0 } },
        { safe => $self->safe, multiple => 1 }
    );
}


sub search {
    my ( $self, $query, $opts ) = @_;
    $query = {} unless ref $query eq 'HASH';
    $opts  = {} unless ref $opts eq 'HASH';
    if ( exists $opts->{reserved} ) {
        $query->{$RESERVED} =
          { '$exists' => $opts->{reserved} ? boolean::true : boolean::false };
        delete $opts->{reserved};
    }
    my $cursor =
      $self->mongo_collection( $self->collection_name )->query( $query, $opts );
    if ( $opts->{fields} && ref $opts->{fields} ) {
        my $spec =
          ref $opts->{fields} eq 'HASH'
          ? $opts->{fields}
          : { map { $_ => 1 } @{ $opts->{fields} } };
        $cursor->fields($spec);
    }
    return $cursor->all;
}


sub peek {
    my ( $self, $task ) = @_;
    my @result = $self->search( { $ID => $task->{$ID} } );
    return wantarray ? @result : $result[0];
}


sub size {
    my ($self) = @_;
    return $self->mongo_collection( $self->collection_name )->count;
}


sub waiting {
    my ($self) = @_;
    return $self->mongo_collection( $self->collection_name )
      ->count( { $RESERVED => { '$exists' => boolean::false } } );
}

__PACKAGE__->meta->make_immutable;

1;


# vim: ts=4 sts=4 sw=4 et:

__END__

=pod

=encoding utf-8

=head1 NAME

MongoDBx::Queue - A message queue implemented with MongoDB

=head1 VERSION

version 1.001

=head1 SYNOPSIS

    use v5.10;
    use MongoDBx::Queue;

    my $queue = MongoDBx::Queue->new(
        database_name => "queue_db",
        client_options => {
            host => "mongodb://example.net:27017",
            username => "willywonka",
            password => "ilovechocolate",
        }
    );

    $queue->add_task( { msg => "Hello World" } );
    $queue->add_task( { msg => "Goodbye World" } );

    while ( my $task = $queue->reserve_task ) {
        say $task->{msg};
        $queue->remove_task( $task );
    }

=head1 DESCRIPTION

MongoDBx::Queue implements a simple, prioritized message queue using MongoDB as
a backend.  By default, messages are prioritized by insertion time, creating a
FIFO queue.

On a single host with MongoDB, it provides a zero-configuration message service
across local applications.  Alternatively, it can use a MongoDB database
cluster that provides replication and fail-over for an even more durable,
multi-host message queue.

Features:

=over 4

=item *

messages as hash references, not objects

=item *

arbitrary message fields

=item *

arbitrary scheduling on insertion

=item *

atomic message reservation

=item *

stalled reservations can be timed-out

=item *

task rescheduling

=item *

automatically creates correct index

=item *

fork-safe

=back

Not yet implemented:

=over 4

=item *

parameter checking

=item *

error handling

=back

Warning: do not use with capped collections, as the queued messages will not
meet the constraints required by a capped collection.

=head1 ATTRIBUTES

=head2 database_name

A MongoDB database name.  Unless a C<db_name> is provided in the
C<client_options> attribute, this database will be the default for
authentication.  Defaults to 'test'

=head2 client_options

A hash reference of L<MongoDB::MongoClient> options that will be passed to its
C<connect> method.

=head2 collection_name

A collection name for the queue.  Defaults to 'queue'.  The collection must
only be used by MongoDBx::Queue or unpredictable awful things will happen.

=head2 safe

Boolean that controls whether 'safe' inserts/updates are done.
Defaults to true.

=head1 METHODS

=head2 new

   $queue = MongoDBx::Queue->new(
        database_name   => "my_app",
        client_options  => {
            host => "mongodb://example.net:27017",
            username => "willywonka",
            password => "ilovechocolate",
        },
   );

Creates and returns a new queue object.

=head2 add_task

  $queue->add_task( \%message, \%options );

Adds a task to the queue.  The C<\%message> hash reference will be shallow
copied into the task and not include objects except as described by
L<MongoDB::DataTypes>.  Top-level keys must not start with underscores, which are
reserved for MongoDBx::Queue.

The C<\%options> hash reference is optional and may contain the following key:

=over 4

=item *

C<priority>: sets the priority for the task. Defaults to C<time()>.

=back

Note that setting a "future" priority may cause a task to be invisible
to C<reserve_task>.  See that method for more details.

=head2 reserve_task

  $task = $queue->reserve_task;
  $task = $queue->reserve_task( \%options );

Atomically marks and returns a task.  The task is marked in the queue as
"reserved" (in-progress) so it can not be reserved again unless is is
rescheduled or timed-out.  The task returned is a hash reference containing the
data added in C<add_task>, including private keys for use by MongoDBx::Queue
methods.

Tasks are returned in priority order from lowest to highest.  If multiple tasks
have identical, lowest priorities, their ordering is undefined.  If no tasks
are available or visible, it will return C<undef>.

The C<\%options> hash reference is optional and may contain the following key:

=over 4

=item *

C<max_priority>: sets the maximum priority for the task. Defaults to C<time()>.

=back

The C<max_priority> option controls whether "future" tasks are visible.  If
the lowest task priority is greater than the C<max_priority>, this method
returns C<undef>.

=head2 reschedule_task

  $queue->reschedule_task( $task );
  $queue->reschedule_task( $task, \%options );

Releases the reservation on a task so it can be reserved again.

The C<\%options> hash reference is optional and may contain the following key:

=over 4

=item *

C<priority>: sets the priority for the task. Defaults to the task's original priority.

=back

Note that setting a "future" priority may cause a task to be invisible
to C<reserve_task>.  See that method for more details.

=head2 remove_task

  $queue->remove_task( $task );

Removes a task from the queue (i.e. indicating the task has been processed).

=head2 apply_timeout

  $queue->apply_timeout( $seconds );

Removes reservations that occurred more than C<$seconds> ago.  If no
argument is given, the timeout defaults to 120 seconds.  The timeout
should be set longer than the expected task processing time, so that
only dead/hung tasks are returned to the active queue.

=head2 search

  my @results = $queue->search( \%query, \%options );

Returns a list of tasks in the queue based on search criteria.  The
query should be expressed in the usual MongoDB fashion.  In addition
to MongoDB options C<limit>, C<skip> and C<sort>, this method supports
a C<reserved> option.  If present, results will be limited to reserved
tasks if true or unreserved tasks if false.

=head2 peek

  $task = $queue->peek( $task );

Retrieves a full copy of the task from the queue.  This is useful to retrieve all
fields from a partial-field result from C<search>.  It is equivalent to:

  $self->search( { _id => $task->{_id} } );

Returns undef if the task is not found.

=head2 size

  $queue->size;

Returns the number of tasks in the queue, including in-progress ones.

=head2 waiting

  $queue->waiting;

Returns the number of tasks in the queue that have not been reserved.

=for Pod::Coverage BUILD

=for :stopwords cpan testmatrix url annocpan anno bugtracker rt cpants kwalitee diff irc mailto metadata placeholders metacpan

=head1 SUPPORT

=head2 Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at L<https://github.com/dagolden/MongoDBx-Queue/issues>.
You will be notified automatically of any progress on your issue.

=head2 Source Code

This is open source software.  The code repository is available for
public review and contribution under the terms of the license.

L<https://github.com/dagolden/MongoDBx-Queue>

  git clone https://github.com/dagolden/MongoDBx-Queue.git

=head1 AUTHOR

David Golden <dagolden@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by David Golden.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004

=cut
