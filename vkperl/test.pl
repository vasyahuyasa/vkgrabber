#!/usr/bin/perl

use strict;
use utf8;
use POSIX qw(strftime);
use Data::Dumper;
use LWP::UserAgent;
use JSON;
use Carp;
use FindBin;                   # locate this script
use lib "$FindBin::Bin/..";    # parent directory
use VkDb;
use feature 'state';           # статические переменные
use Try::Tiny;

use constant {
	APIVER  => '5.50',
	APIURL  => 'https://api.vk.com/method/',
	BASEURL => 'https://vk.com/',
	CONFIG  => 'config.json',
	DEBUG   => 1
};

my $str;
my $fname = CONFIG;
{
	local $/;
	open my $fh, '<', $fname or die "can't open config $fname: .$!";
	$str = <$fh>;
}
my $globalConfig   = decode_json($str);
my $user           = $globalConfig->{'database'}->{'mysql'}->{'user'};
my $password       = $globalConfig->{'database'}->{'mysql'}->{'password'};
my $database       = $globalConfig->{'database'}->{'mysql'}->{'database'};
my $server         = $globalConfig->{'database'}->{'mysql'}->{'server'};
my $vkdb           = VkDb->new($user, $password, $database, $server);
my $globalProfiles = $vkdb->getProfiles();

my @profile_names = keys %{$globalProfiles};
for my $name (@profile_names) {
	my $group = $globalProfiles->{$name};
	my @emails = @{ $group->{'emails'} };
	if (scalar(@emails)) {

		# отправить всем адресатам
		for my $email (@emails) {
			print "group: $group email: $email\n";
		}
	}
}
