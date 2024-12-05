# == Define: luks::device
#
# Creates an encrypted LUKS device mapping.
#
# Warning: This will overwrite any existing data on the specified device.
#
# Warning: The secret key may still be cached by Puppet in the compiled catalog
#  (/var/lib/puppet/client_data/catalog/*.json)  To prevent this secret from
#  persisting on disk you will have still have delete this file via some
#  mechanism, e.g., through a cron task or configuring the Puppet agent to
#  run a `postrun_command`, see:
#
#  http://docs.puppetlabs.com/references/stable/configuration.html#postruncommand
#
# === Parameters
#
# [*device*]
#  The hardware device to back LUKS with -- any existing data will be
#  lost when formatted as a LUKS device!
#
# [*key*]
#  The encryption key for the LUKS device.
#
# [*base64*]
#  Set to true if the key is base64-encoded (necessary for encryption keys
#  with binary data); defaults to false.
#
# [*mapper*]
#  The name to use in `/dev/mapper` for the device, defaults to the name
#  to the name of the resource.
#
# [*force_format*]
# Instructs LuksFormat to run in 'batchmode' which esentially forces the block device
# to be formatted, use with care.
#
# === Example
#
# The following creates a LUKS device at '/dev/mapper/data', backed by
# the partition at '/dev/sdb1', encrypted with the key 's3kr1t':
#
#   luks::device { 'data':
#     device => '/dev/sdb1',
#     key    => 's3kr1t',
#   }
#
define luks::device(
  $device,
  $key,
  $base64 = false,
  $mapper = $name,
  $force_format = false,
) {
  # Ensure LUKS is available.
  include luks

  # Setting up unique variable names for the resources.
  $devmapper = "/dev/mapper/${mapper}"
  $luks_format = "luks-format-${name}"
  $luks_open = "luks-open-${name}"
  $luks_keychange = "luks-keychange-${name}"

  if $base64 {
    $echo_cmd = '/usr/bin/echo -n "$(puppet node decrypt --env CRYPTKEY)" | /usr/bin/base64 -d'
  } else {
    $echo_cmd = '/usr/bin/echo -n "$(puppet node decrypt --env CRYPTKEY)"'
  }

  $cryptsetup_cmd = '/sbin/cryptsetup'
  $cryptsetup_key_cmd = "${echo_cmd} | ${cryptsetup_cmd} --key-file -"
  $master_key_cmd = "dmsetup table --target crypt --showkey ${devmapper} | cut -f5 -d\" \" | xxd -r -p"

  if $force_format == true {
    $format_options = '--batch-mode'
  } else {
    $format_options = ''
  }

  $node_encrypted_key = node_encrypt($key)
  redact('key') # Redact the passed in parameter from the catalog

  # Format as LUKS device if it isn't already.
  exec { $luks_format:
    command     => "${cryptsetup_key_cmd} luksFormat ${format_options} ${device}",
    user        => 'root',
    unless      => "${cryptsetup_cmd} isLuks ${device}",
    environment => "CRYPTKEY=${node_encrypted_key}",
    require     => Class['luks'],
  }

  # Open the LUKS device.
  exec { $luks_open:
    command     => "${cryptsetup_key_cmd} luksOpen ${device} ${mapper}",
    user        => 'root',
    onlyif      => "/usr/bin/test ! -b ${devmapper}", # Check devmapper is a block device
    environment => "CRYPTKEY=${node_encrypted_key}",
    creates     => $devmapper,
    require     => Exec[$luks_format],
  }

  # Key change. Will only work if device currently open.
  # Currently will only add a changed key, old one will remain until manually removed.
  exec { $luks_keychange:
    command     => "bash -c '${cryptsetup_key_cmd} luksAddKey --master-key-file <(${master_key_cmd}) ${device} -'",
    user        => 'root',
    unless      => "${cryptsetup_key_cmd} luksDump ${device} --dump-master-key --batch-mode > /dev/null",
    environment => "CRYPTKEY=${node_encrypted_key}",
    require     => Exec[$luks_open],
  }
}
