# == Class: percona::node
#
# Installs and configures a percona node and associated MySQL service. 
# By default, this class configures a new cluster consisting of a single node.
# Subsequent nodes can be joined to the cluster by setting the $joiner parameter
# to true and nominating a donor via the $donor_ip parameter.
#
# === Parameters
# 
#   [*cluster_name*]
#    Type: String. Default: 'my_cluster'. Name of the cluster to create or join.
#
#   [*joiner*]
#    Type: Bool. Default: 'false'. Is the node joining an existing cluster?
#
#   [*donor_ip*] 
#    Type: String. Default: '0.0.0.0'. IP of pre-existing node to perform an
#    initial state transfer from when joining a cluster.
#
#   [*sst_method*] 
#    Type: String. Default: 'xtrabackup-v2'. SST (state transfer method) to when joining
#    a cluster. Other possibilities are 'xtrabackup', 'rsync' and 'mysqldump'. See galera docs for
#    further info.
#
#   [*sst_user*]
#    Type: String. Default: 'wsrep_sst'. MySQL user that performs the SST. Only used for the 'mysqldump' SST method.
#
#   [*sst_password*]
#    Type: String. Default: 'password'. Password for SST MySQL user.
#
#   [*root_password*]
#    Type: String. Default: 'password'. Password for the MySQL root user.
#
#   [*maint_password*]
#    Type: String. Default: 'maint'. Password for the debian_sys_maint MySQL user.
#
#   [*old_root_password*]
#     Type: String. Default: ''.
#
#   [*enabled*]
#     Type: Bool. Default: true. Enable or disable the MySQL/Percona service.
#
#   [*package_name*]
#     Type: String. Default: 'percona-xtradb-cluster-server-5.6'. Name of the percona package to install.
#
# === Examples
#
#   To create a new cluster from scratch:
#
#   node percona-node1 {
#     class { 'percona::node':   
#            cluster_name => 'cluster',
#     }
#   }
#
#   Add more nodes to the cluster once the first node is up and running: 
# 
#   node percona-node2 {
#     class { 'percona::node':   
#            cluster_name => 'cluster',
#            joiner       => true,
#            donor_ip     => 'ip.of.first.node',
#     }
#   }
#
#   Percona recommend not to add a large number of nodes at once as this could overwhelm the initial node with state transfer events.
#
#   !! IMPORTANT !!: In order to avoid the cluster becoming partitioned, the initial node
#   *must* be redefined as a joiner with a donor IP (*not* it's own address) once the cluster
#   has been fully created.
#
class percona::node (
    $cluster_name	     = 'my_cluster', 
    $joiner 		       = false,
    $donor_ip          = '0.0.0.0',
    $sst_method        = 'xtrabackup-v2',
    $sst_user          = 'wsrep_sst',
    $sst_password      = 'password',
    $root_password     = 'password',
    $maint_password    = 'maint',
    $old_root_password = '',
    $enabled           = true,
    $package_name      = 'percona-xtradb-cluster-server-5.6',
) {

  if $enabled {
   $service_ensure = 'running'
  } else {
   $service_ensure = 'stopped'
  }

  # Enable percona repo to get more up to date versions.
  include apt

  # Chain percona apt source, apt-get update (notify) and 
  # percona package install (depends on apt-get update running first).
  apt::source { 'percona':
      location   => 'http://repo.percona.com/apt',
      release    => $::lsbdistcodename,
      repos      => 'main',
      key        => {
          'id'     => '430BDF5C56E7C94E848EE60C1C4CBDCDCD2EFD2A',
          'server' => 'pool.sks-keyservers.net',
      },
  } ~>
  exec { 'update':
    command     => "/usr/bin/apt-get update",
    refreshonly => true,
  } ->
  package { $package_name:
       alias   => 'mysql-server',
       ensure  => installed,
  }
  # End of chain.

  # Create mysql user. Required for setting file ownership.
  user { 'mysql':
       ensure => present,
  }

  file { '/etc/mysql':
       ensure => directory,
       mode   => '0755',
  }
  file { '/etc/mysql/conf.d':
       ensure => directory,
       mode   => '0755',
  }

  file { "/etc/mysql/my.cnf":
       ensure  => present,
       source  => 'puppet:///modules/percona/my.cnf',
       require => File['/etc/mysql'],
       notify  => Class['::percona:service'],
  }

  file { "/usr/local/bin/perconanotify.py":
       ensure => present,
       source => 'puppet:///modules/percona/perconanotify.py',
       mode   => '0755',
  }

  file { "/etc/mysql/conf.d/wsrep.cnf":
       ensure  => present,
       owner   => 'mysql',
       group   => 'mysql',
       mode    => '0600',
       content => template("percona/wsrep.cnf.erb"),
       require => [
             File['/etc/mysql', '/etc/mysql/conf.d', '/usr/local/bin/perconanotify.py'],
             User['mysql'],
       ],
       notify  => Class['::percona:service'],
  }

  file { "/etc/mysql/conf.d/utf8.cnf":
       ensure  => present,
       source => 'puppet:///modules/percona/utf8.cnf',
       require => File['/etc/mysql', '/etc/mysql/conf.d'],
       notify  => Class['::percona:service'],
  }

  file { '/etc/mysql/debian.cnf':
       ensure  => present,
       owner   => 'mysql',
       group   => 'mysql',
       mode    => '0600',
       content => template('percona/debian.cnf.erb'),
       require => [
             Class['::percona::service'], # I want this to change after a refresh
             File['/etc/mysql', '/etc/mysql/conf.d'],
             User['mysql'],
       ],
  }

  # SSL key+cert for authenticated replication
  file { '/etc/mysql/replication-key.pem':
       ensure  => present,
       owner   => 'mysql',
       group   => 'mysql',
       mode    => '0600',
       source  => 'puppet:///modules/percona/replication-key.pem',
       require => [
             File['/etc/mysql', '/etc/mysql/conf.d'],
             User['mysql'],
       ]
  }

  file { '/etc/mysql/replication-cert.pem':
       ensure  => present,
       owner   => 'mysql',
       group   => 'mysql',
       mode    => '0644',
       source  => 'puppet:///modules/percona/replication-cert.pem',
       require => File['/etc/mysql/replication-key.pem'],
       notify  => Class['::percona:service'],
  }

  file { '/etc/logrotate.d/percona':
       ensure  => present,
       source  => 'puppet:///modules/percona/percona-logrotate',
  }

  file { '/root/.my.cnf':
       content => template('percona/my.cnf.pass.erb'),
       mode    => '0600',
       require => Exec['set_mysql_rootpw'],
  }

  # This kind of sucks, that I have to specify a difference resource for
  # restart.  the reason is that I need the service to be started before mods
  # to the config file which can cause a refresh
  exec { 'mysqld-restart':
    command     => "service mysql restart",
    logoutput   => on_failure,
    refreshonly => true,
    path        => '/sbin/:/usr/sbin/:/usr/bin/:/bin/',
  }

  # manage root password if it is set
  if $root_password != 'UNSET' {
    case $old_root_password {
      '':      { $old_pw='' }
      default: { $old_pw="-p${old_root_password}" }
    }

    exec { 'set_mysql_rootpw':
      command   => "mysqladmin -u root ${old_pw} password ${root_password}",
      logoutput => true,
      unless    => "mysqladmin -u root -p${root_password} status > /dev/null",
      path      => '/usr/local/sbin:/usr/bin:/usr/local/bin',
      notify    => Exec['mysqld-restart'],
      require   => [ 
            File['/etc/mysql/conf.d'],
            Class['::percona::service']
      ],
    }

     exec { "set-mysql-password-noroot":
        unless      => "/usr/bin/mysql -u${sst_user} -p${sst_password}",
        command     => "/usr/bin/mysql -uroot -p -e \"set wsrep_on='off'; delete from mysql.user where user=''; grant all on *.* to '${sst_user}'@'%' identified by '${sst_password}';flush privileges;\"",
        require     => Class['::percona::service'],
        subscribe   => Class['::percona::service'],
        refreshonly => true,
    }
  }

    exec { "set-mysql-password":
        unless      => "/usr/bin/mysql -u${sst_user} -p${sst_password}",
        command     => "/usr/bin/mysql -uroot -p${root_password} -e \"set wsrep_on='off'; delete from mysql.user where user=''; grant all on *.* to '${sst_user}'@'%' identified by '${sst_password}';flush privileges;\"",
        require     => Class['::percona::service'],
        subscribe   => Class['::percona::service'],
        refreshonly => true,
    }

  # The debian-sys-maint user needs to have identical credentials across the cluster
  percona::rights { 'debian-sys-maint user':
       database        => '*',
       user            => 'debian-sys-maint',
       password        => $maint_password,
       priv            => 'SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, SHUTDOWN, PROCESS, FILE, REFERENCES, INDEX, ALTER, SHOW DATABASES, SUPER, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER',
       grant_option    => true,
       require         => [
          Class['::percona::service'],
          File['/root/.my.cnf']
      ],
  }

  # Make sure percona package is installed before trying to do anything with the service
  Package[$package_name] -> Class['::percona::service']

  class { '::percona::service':
      service_ensure => $service_ensure,
      service_enable => $enabled,
  }
}
