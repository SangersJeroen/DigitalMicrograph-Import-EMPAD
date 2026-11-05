// Import_EMPAD.s
// Imports an EMPAD acquisition (.xml + .raw) as a 4D-STEM "Diffraction SI" in DigitalMicrograph.
//
// Result: 4D float image, DM dimensions [qx, qy, scan x, scan y], displayed as a scan image
// (sum over the diffraction pattern) with the GMS Diffraction-SI tags.
//
// - A file dialog asks for the .xml (selecting the .raw also works).
// - The .raw file name is read from <raw_file filename="..."/> in the XML.
// - Scan size: every <scan_parameters ...> block (search, acquire, ...) is tried and the one that
//   matches the number of frames in the .raw file is used; <pix_x>/<pix_y> are tried as well.
//   Non-square scans are fine. If nothing matches you are asked for the scan size.
// - Calibration follows RosettaSciIO's EMPAD reader: scan step = full scan field of view * scan_size
//   / number of steps (nm); detector axes use <calibrated_pixelsize> if present, else pixels.
// - Raw format: float32 frames of 130 rows x 128 columns; rows 128-129 are per-frame metadata and
//   are dropped.
// Note: for large datasets DM needs about twice the data size in memory while importing.

number kDetX = 128
number kDetY = 130      // 128 detector rows + 2 metadata rows
number kDetYCrop = 128

// text between <tag ...> and </tag> (first element named exactly 'tag'), or ""
string XmlValue(string xml, string tag)
{
	number pos = 0, a, b, e, start
	string nc
	while (pos < len(xml))
	{
		a = find(mid(xml, pos, len(xml) - pos), "<" + tag)
		if (a < 0) return ""
		a += pos
		nc = mid(xml, a + len(tag) + 1, 1)
		if (nc == ">" || nc == " " || nc == "/")
		{
			b = find(mid(xml, a, len(xml) - a), ">")
			if (b < 0) return ""
			start = a + b + 1
			e = find(mid(xml, start, len(xml) - start), "</" + tag + ">")
			if (e < 0) return ""
			return mid(xml, start, e)
		}
		pos = a + 1
	}
	return ""
}

// value of attribute 'attr' of the first <tag ...> element, or ""
string XmlAttr(string xml, string tag, string attr)
{
	number a = find(xml, "<" + tag)
	if (a < 0) return ""
	string rest = mid(xml, a, len(xml) - a)
	number b = find(rest, ">")
	if (b < 0) return ""
	string el = left(rest, b)
	number c = find(el, attr + "=\"")
	if (c < 0) return ""
	number vstart = c + len(attr) + 2
	string v = mid(el, vstart, len(el) - vstart)
	number d = find(v, "\"")
	if (d < 0) return ""
	return left(v, d)
}

// ---- file selection ----
string xmlPath, rawPath
if (!OpenDialog(NULL, "Select the EMPAD .xml file", "", xmlPath)) exit(0)
if (right(xmlPath, 4) == ".raw" || right(xmlPath, 4) == ".RAW")
{
	rawPath = xmlPath
	xmlPath = left(rawPath, len(rawPath) - 4) + ".xml"
}

// directory and file name of the selected file
number lastSep = -1, i
string ch
for (i = 0; i < len(xmlPath); i++)
{
	ch = mid(xmlPath, i, 1)
	if (ch == "\\" || ch == "/") lastSep = i
}
string dirPath = left(xmlPath, lastSep + 1)
string xmlFile = mid(xmlPath, lastSep + 1, len(xmlPath) - lastSep - 1)
string baseName = left(xmlFile, len(xmlFile) - 4)

// ---- metadata from XML ----
string xml = ""
if (DoesFileExist(xmlPath))
{
	number fx = OpenFileForReading(xmlPath)
	object sx = NewStreamFromFileReference(fx, 1)
	xml = sx.StreamReadAsText(0, sx.StreamGetSize())
	CloseFile(fx)
	if (rawPath == "")
	{
		string rawName = XmlAttr(xml, "raw_file", "filename")
		if (rawName != "") rawPath = dirPath + rawName
	}
}
if (rawPath == "" || !DoesFileExist(rawPath))
{
	Result("\nCould not find the .raw file (" + rawPath + "). Select it manually.")
	if (!OpenDialog(NULL, "Select the EMPAD .raw file", "", rawPath)) exit(0)
}

// ---- open raw file, count frames ----
number fileID = OpenFileForReading(rawPath)
object stream = NewStreamFromFileReference(fileID, 1)
number nFrames = stream.StreamGetSize() / (kDetX * kDetY * 4)

// ---- find the scan size that matches the number of frames ----
number nx = 0, ny = 0, pos = 0, a, found = 0
string blk, scanBlk = ""
while (!found && pos < len(xml))
{
	a = find(mid(xml, pos, len(xml) - pos), "<scan_parameters")
	if (a < 0) break
	pos += a + 1
	blk = mid(xml, pos - 1, len(xml) - pos + 1)          // from this block onwards
	nx = val(XmlValue(blk, "scan_resolution_x"))
	ny = val(XmlValue(blk, "scan_resolution_y"))
	if (nx > 0 && ny > 0 && nx * ny == nFrames)
	{
		found = 1
		scanBlk = blk
	}
}
if (!found)
{
	nx = val(XmlValue(xml, "pix_x"))
	ny = val(XmlValue(xml, "pix_y"))
	if (nx > 0 && ny > 0 && nx * ny == nFrames) found = 1
}
if (!found)
{
	Result("\nNo scan size in the XML matches the " + nFrames + " frames in the .raw file.")
	nx = round(sqrt(nFrames)); ny = nx
	if (!GetNumber("Scan size X (frames in file: " + nFrames + ")", nx, nx)) exit(0)
	if (!GetNumber("Scan size Y", ny, ny)) exit(0)
	if (nx * ny != nFrames) Throw("Scan size does not match the number of frames in the file.")
}
Result("\nEMPAD: " + nx + " x " + ny + " scan positions, raw file " + rawPath)

// ---- read all frames (130 rows) into a 4D image: dims = qx, qy, scan x, scan y ----
image raw4d := RealImage("EMPAD raw", 4, kDetX, kDetY, nx, ny)
ImageReadImageDataFromStream(raw4d, stream, 0)     // 0 = default endianness (EMPAD files are little endian, as on Windows PCs)
CloseFile(fileID)

// ---- drop the two metadata rows (note '=': SliceN returns a view, we want an independent copy) ----
image img4d = raw4d.SliceN(4, 4, 0,0,0,0,  0,kDetX,1,  1,kDetYCrop,1,  2,nx,1,  3,ny,1)
DeleteImage(raw4d)
img4d.SetName(baseName + " (EMPAD 4D-STEM)")

// ---- calibration (following the logic of rsciio's EMPAD reader) ----
// scan step: full scan field of view (m) * scan_size (fraction of the full field) / number of steps
// detector: <calibrated_pixelsize> (if present) is taken in 1/m -> 1/nm (as rsciio does); else pixels
number stepX = 1, stepY = 1, qScale = 1
string scanUnit = "px", qUnit = "px"
string fovBlk = XmlValue(xml, "full_scan_field_of_view")
number fovX = val(XmlValue(fovBlk, "x"))
number fovY = val(XmlValue(fovBlk, "y"))
number scanFrac = 1
string scanSizeStr = XmlValue(scanBlk, "scan_size")
if (scanSizeStr != "") scanFrac = val(scanSizeStr)
if (fovBlk != "" && fovX > 0 && fovY > 0)
{
	stepX = fovX * scanFrac / nx * 1e9
	stepY = fovY * scanFrac / ny * 1e9
	scanUnit = "nm"
}
string pixSizeStr = XmlValue(xml, "calibrated_pixelsize")
if (pixSizeStr != "")
{
	qScale = val(pixSizeStr) * 1e9
	qUnit = "1/nm"
}
number voltage = val(XmlValue(xml, "high_voltage"))

// diffraction dims 0,1 (pattern centre at zero: the script "origin" is the coordinate of the first pixel), scan dims 2,3
img4d.ImageSetDimensionOrigin(0, -(kDetX / 2) * qScale)
img4d.ImageSetDimensionScale(0, qScale)
img4d.ImageSetDimensionUnitString(0, qUnit)
img4d.ImageSetDimensionOrigin(1, -(kDetYCrop / 2) * qScale)
img4d.ImageSetDimensionScale(1, qScale)
img4d.ImageSetDimensionUnitString(1, qUnit)
img4d.ImageSetDimensionOrigin(2, 0)
img4d.ImageSetDimensionScale(2, stepX)
img4d.ImageSetDimensionUnitString(2, scanUnit)
img4d.ImageSetDimensionOrigin(3, 0)
img4d.ImageSetDimensionScale(3, stepY)
img4d.ImageSetDimensionUnitString(3, scanUnit)

// ---- tags (those GMS sets on a native Diffraction SI) ----
TagGroup tg = img4d.ImageGetTagGroup()
tg.TagGroupSetTagAsString("Meta Data:Format", "Diffraction image")
tg.TagGroupSetTagAsString("Meta Data:Acquisition Mode", "Parallel imaging")
tg.TagGroupSetTagAsBoolean("Meta Data:Data Order Swapped", 1)
TagGroup kw = NewTagList()
TagGroup kw1 = NewTagGroup()
kw1.TagGroupSetTagAsString("Label", "Spectrum Imaging")
kw.TagGroupInsertTagAsTagGroup(kw.TagGroupCountTags(), kw1)
TagGroup kw2 = NewTagGroup()
kw2.TagGroupSetTagAsString("Label", "Diffraction")
kw.TagGroupInsertTagAsTagGroup(kw.TagGroupCountTags(), kw2)
tg.TagGroupSetTagAsTagGroup("Meta Data:Experiment keywords", kw)
tg.TagGroupSetTagAsString("Microscope Info:Illumination Mode", "STEM")
tg.TagGroupSetTagAsString("Microscope Info:Imaging Mode", "DIFFRACTION")
tg.TagGroupSetTagAsString("Microscope Info:Operation Mode", "SCANNING")
if (voltage > 0) tg.TagGroupSetTagAsNumber("Microscope Info:Voltage", voltage)
tg.TagGroupSetTagAsLong("DigiScan:Image Width", nx)
tg.TagGroupSetTagAsLong("DigiScan:Image Height", ny)
tg.TagGroupSetTagAsString("EMPAD:Source raw", rawPath)
tg.TagGroupSetTagAsString("EMPAD:Source xml", xmlPath)

// ---- display as Diffraction SI: scan image = sum over (part of) the diffraction pattern ----
// the display is created explicitly (ShowImage alone creates it only after the script has finished)
ImageDisplay disp = img4d.ImageCreateImageDisplay(1)               // 1 = raster display
object src = New4DSummedImageSource(img4d, 0, 1, 1)                // sum over dims 0,1 (diffraction) -> scan image
disp.ImageDisplaySetImageSource(src)
disp.ImageDisplaySetDisplayedLayers(0, kDetX - 1, 0, kDetYCrop - 1)   // all detector pixels summed
ImageDocument doc = img4d.ImageGetOrCreateImageDocument()
doc.ImageDocumentShow()
Result("\nImported EMPAD " + nx + " x " + ny + " scan of " + kDetX + " x " + kDetYCrop + " patterns (" + stepX + " " + scanUnit + " per step).")
