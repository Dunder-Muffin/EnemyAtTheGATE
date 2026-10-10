-- AnteUp2 build version, compared between client and server by AnteCore/VersionCheck.
--   * _Export-AnteUp2.ps1 stamps the release number into the COPY it zips and sets Dev = false
--     there. This dev tree stays Dev = true, so a dev build never passes for a release.
--   * Minor here is just the last release this tree was exported as.
return {
    Major = 1,
    Minor = 34,
    Dev = false,
}
