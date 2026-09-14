# One key and certificate sign everything: the UKI and systemd-boot for Secure
# Boot, and the /usr verity root hash. The same certificate is enrolled as PK,
# KEK and db, which is what mkosi does too - there is no one else in the chain.

use common.nu *

# Generate the pair, or import an existing one with --key and --cert (elvOS's
# mkosi.key/mkosi.crt: machines that enrolled it keep booting what elv signs).
# Keys already there are only replaced with --force, and then moved into a
# dated folder, never deleted.
export def main [--force, --key: path, --cert: path] {
    let dir = (keys-dir)
    let db_key = ($dir | path join db.key)
    let db_crt = ($dir | path join db.crt)

    if ($key == null) != ($cert == null) {
        error make { msg: "--key and --cert go together" }
    }
    if ($db_key | path exists) {
        if not $force {
            error make { msg: $"keys already exist in ($dir) - pass --force to replace them, which invalidates every image signed so far and any firmware that enrolled them" }
        }
        let old = ($dir | path join $"replaced-(date now | format date '%Y%m%d-%H%M%S')")
        mkdir $old
        for f in [db.key db.crt auto] {
            let p = ($dir | path join $f)
            if ($p | path exists) { mv $p $old }
        }
        print $"  previous keys moved to ($old)"
    }

    mkdir $dir
    if $key != null {
        # The certificate must be the key's own, or everything signed would
        # fail to verify against what the firmware enrolled.
        let a = (^openssl pkey -in $key -pubout | complete)
        let b = (^openssl x509 -in $cert -noout -pubkey | complete)
        if $a.exit_code != 0 or $b.exit_code != 0 or $a.stdout != $b.stdout {
            error make { msg: $"($cert) is not the certificate of ($key)" }
        }
        step $"importing ($key | path basename) and ($cert | path basename)"
        cp $key $db_key
        ^openssl x509 -in $cert -out $db_crt
    } else {
        step "generating the signing key and certificate"
        (^openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650
            -subj $"/CN=((config).id) Secure Boot"
            -keyout $db_key -out $db_crt) e>| ignore
    }
    chmod 600 $db_key

    # Enrollment variables for systemd-boot's secure-boot-enroll: signed EFI
    # signature lists it writes into PK, KEK and db the first time it boots
    # with Secure Boot in setup mode.
    step "generating Secure Boot enrollment files"
    let auto = ($dir | path join auto)
    mkdir $auto
    let der = ($dir | path join db.der)
    let esl = ($dir | path join db.esl)
    ^openssl x509 -in $db_crt -outform DER -out $der
    ^sbsiglist --owner (random uuid) --type x509 --output $esl $der

    for var in [PK KEK db] {
        (^sbvarsign --attr NON_VOLATILE,BOOTSERVICE_ACCESS,RUNTIME_ACCESS,TIME_BASED_AUTHENTICATED_WRITE_ACCESS
            --key $db_key --cert $db_crt --output ($auto | path join $"($var).auth") $var $esl) out> /dev/null
    }
    rm $der $esl

    print $"  ($db_crt)"
    ^openssl x509 -in $db_crt -noout -subject -enddate | lines | each { |l| print $"  ($l)" } | ignore
}
