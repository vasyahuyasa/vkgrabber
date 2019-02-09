package VkDb;

use strict;
use Exporter;
use vars qw($VERSION);
use DBI;
use Data::Dumper;
use JSON;
$VERSION = 0.1;

use constant DATATABLE   => 'modx_vk_comments';
use constant CONFIGTABLE => 'modx_vk_configs';

# args - парметры соединения с БД
sub new {
	my ($class, $user, $password, $dbname, $server) = @_;

	# хэш содержащий свойства объекта
	my $connect = "DBI:mysql:$dbname:$server";
	my $self    = {
		name    => 'VkDb',
		version => '0.1',
		dbh     => DBI->connect($connect, $user, $password)
	};

	die if !defined($self->{dbh});

	bless $self, $class;
	return $self;
}

sub DESTROY {
	my ($self) = @_;

	# TODO close connection
}

sub addComment {
	my ($self, $group, $type, $gid, $pid, $date, $comment_id, $text, $profile) = @_;

	my $dbh         = $self->{dbh};
	my $text_pofile = encode_json($profile);
	my $query       = "INSERT INTO " . DATATABLE . " (`type`, `gid`, `pid`,  `comment_id`, `date`, `text`, `user_profile`) VALUES ('$type', $gid, $pid, $comment_id, $date, '$text', '$text_pofile')";
	my $sth         = $dbh->prepare($query);
	$sth->execute();
}

sub getLastComment {
	my ($self, $type, $gid, $pid) = @_;

	my $dbh   = $self->{dbh};
	my $query = "SELECT * FROM " . DATATABLE . " WHERE (gid = $gid AND pid = $pid AND type LIKE '$type') ORDER by comment_id DESC LIMIT 1";
	my $sth   = $dbh->prepare($query);
	$sth->execute();
	my $res = $sth->fetchrow_hashref;
	return $res;
}

sub getProfiles {
	my ($self) = @_;

	my $dbh   = $self->{dbh};
	my $query = "SELECT * FROM " . CONFIGTABLE;
	my $sth   = $dbh->prepare($query);
	$sth->execute();
	my $profiles;

	while (my $row = $sth->fetchrow_hashref) {
		my $name   = $row->{'name'};
		my $email  = $row->{'email'};
		my $emails = decode_json($row->{'emails'});
		my $links  = decode_json($row->{'data'});
		$profiles->{$name} = {
			'email'  => $email,
			'emails' => $emails,
			'links'  => $links
		};
	}
	return $profiles;
}

1;    # ok!
