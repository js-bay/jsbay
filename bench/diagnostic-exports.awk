{
    name = $NF
    sub(/^_/, "", name)
    if (name ~ /^jsbay_[A-Za-z0-9_]+$/ && name !~ /^jsbay_qjs_/) print name
}
