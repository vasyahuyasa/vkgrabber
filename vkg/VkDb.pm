package VkDb;

use strict;
use Exporter;
use vars qw($VERSION);
use DBI;
use Data::Dumper;
$VERSION = 0.1;

my $dbh;
use constant DATATABLE => 'comments';

# args - парметры соединения с БД
sub new {
	my ($class, $user, $password, $dbname, $server) = @_;

	# хэш содержащий свойства объекта
	my $self = {
		name    => 'VkDb',
		version => '0.1',
	};

	if (!defined $dbh) {
		my $connect = "DBI:mysql:$dbname:$server";
		$dbh = DBI->connect($connect, $user, $password) or die;
	}

	bless $self, $class;
	return $self;
}

sub DESTROY {
	my ($self) = @_;

	# TODO close connection
}

sub addComment {
	my ($self, $group, $type, $gid, $pid, $date, $comment_id, $text) = @_;
	my $query = "INSERT INTO " . DATATABLE . " (`group`, `type`, `gid`, `pid`, `date`, `comment_id`, `text`) VALUES ('$group', '$type', $gid, $pid, $date, $comment_id, '$text')";
	my $sth   = $dbh->prepare($query);
	$sth->execute();
}

sub getLastComment {
	my ($self, $type, $gid, $pid) = @_;
	my $query = "SELECT * FROM " . DATATABLE . " WHERE (gid = $gid AND pid = $pid AND type LIKE '$type') ORDER by comment_id DESC LIMIT 1";

	#print "SQL: $query";
	my $sth = $dbh->prepare($query);
	$sth->execute();
	my $res = $sth->fetchrow_hashref;
	return $res;
}

1;    # ok!
