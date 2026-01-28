mkdir source
mkdir output

cp -r DEBIAN source/
cp -r usr source/
cp -r etc source/
cp -r schemas source/

rm -r source/etc/skel
rm -r source/etc/vasakos

dpkg-deb --build --root-owner-group source output/vasak-desktop-settings_0.1.3_all.deb