# One key and certificate sign everything: the UKI and systemd-boot for Secure
# Boot, and the /usr verity root hash. The same certificate is enrolled as PK,
# KEK and db, which is what mkosi does too - there is no one else in the chain.

use common.nu *

export def main [--force] {
    let dir = (keys-dir)
    let key = ($dir | path join db.key)
    let crt = ($dir | path join db.crt)

    if ($key | path exists) and not $force {
        error make { msg: $"keys already exist in ($dir) - pass --force to replace them, which invalidates every image signed so far and any firmware that enrolled them" }
    }

    mkdir $dir
    step "generating the signing key and certificate"
    (^openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650
        -subj $"/CN=((config).id) Secure Boot"
        -keyout $key -out $crt) e>| ignore
    chmod 600 $key

    # Enrollment variables for systemd-boot's secure-boot-enroll: signed EFI
    # signature lists it writes into PK, KEK and db the first time it boots
    # with Secure Boot in setup mode.
    step "generating Secure Boot enrollment files"
    let auto = ($dir | path join auto)
    mkdir $auto
    let der = ($dir | path join db.der)
    let esl = ($dir | path join db.esl)
    ^openssl x509 -in $crt -outform DER -out $der
    ^sbsiglist --owner (random uuid) --type x509 --output $esl $der

    for var in [PK KEK db] {
        (^sbvarsign --attr NON_VOLATILE,BOOTSERVICE_ACCESS,RUNTIME_ACCESS,TIME_BASED_AUTHENTICATED_WRITE_ACCESS
            --key $key --cert $crt --output ($auto | path join $"($var).auth") $var $esl) out> /dev/null
    }
    rm $der $esl

    print $"  ($crt)"
    ^openssl x509 -in $crt -noout -subject -enddate | lines | each { |l| print $"  ($l)" } | ignore
}
