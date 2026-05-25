// Minimal reproduction of a memory leak in AcDbMText::text() in RealDWG.
//
// Symptom:
//   When AcDbMText is loaded via AcDbDatabase::readDwgFile() and text() is
//   called on it, RealDWG leaks into an internal pool allocator. The leak
//   is proportional to MText content size and accelerates with format codes
//   (e.g. \f, \C, \H). The leaked memory is only released by acdbCleanUp()
//   at process shutdown -- closing the entity and destroying the AcDbDatabase
//   do not return it.
//
// The same content set on an in-memory AcDbMText (no readDwgFile) does NOT
// leak when text() is called on it.
//
// See README.md for full reproduction guide, measurements, and analysis.
//
// MIT licensed.

#include <iostream>
#include <string>
#include <filesystem>
#include <windows.h>

#include <dbapserv.h>
#include <dbents.h>
#include <rxregsvc.h>

namespace {

class MinimalHost : public AcDbHostApplicationServices
{
public:
    MinimalHost(std::wstring realDwgDir, std::wstring regKey)
        : m_dir(std::move(realDwgDir)), m_key(std::move(regKey)) {}

    const ACHAR* getMachineRegistryProductRootKey() override { return m_key.c_str(); }
    const ACHAR* getAlternateFontName() const override { return L"txt.shx"; }

    // Optional: log every findFile() call (proves font lookups are not the cause).
    void setFindFileLog(FILE* log) { m_log = log; }

    Acad::ErrorStatus findFile(
        ACHAR* pathBuffer, int pathBufferSize, const ACHAR* inputFile,
        AcDbDatabase* /*db*/, AcDbHostApplicationServices::FindFileHint hint) override
    {
        wchar_t ext[5] = {0};
        const wchar_t* hintName = L"?";
        switch (hint) {
            case kCompiledShapeFile: wcscpy_s(ext, L".shx"); hintName=L"shx"; break;
            case kTrueTypeFontFile:  wcscpy_s(ext, L".ttf"); hintName=L"ttf"; break;
            case kPatternFile:       wcscpy_s(ext, L".pat"); hintName=L"pat"; break;
            case kARXApplication:    wcscpy_s(ext, L".dbx"); hintName=L"dbx"; break;
            case kFontMapFile:       wcscpy_s(ext, L".fmp"); hintName=L"fmp"; break;
            case kXRefDrawing:       wcscpy_s(ext, L".dwg"); hintName=L"dwg"; break;
            default:                                          hintName=L"def"; break;
        }
        wchar_t* fp = nullptr;
        auto fonts = (std::filesystem::path(m_dir) / L"Fonts").wstring();
        Acad::ErrorStatus rc = Acad::eFilerError;
        if (SearchPath(nullptr,       inputFile, ext, pathBufferSize, pathBuffer, &fp) ||
            SearchPath(fonts.c_str(), inputFile, ext, pathBufferSize, pathBuffer, &fp) ||
            SearchPath(m_dir.c_str(), inputFile, ext, pathBufferSize, pathBuffer, &fp))
            rc = Acad::eOk;

        if (m_log) {
            fwprintf(m_log, L"[%s] %s => %s%s\n", hintName, inputFile,
                     (rc == Acad::eOk) ? L"OK " : L"MISS ",
                     (rc == Acad::eOk) ? pathBuffer : L"");
            fflush(m_log);
        }
        return rc;
    }

private:
    std::wstring m_dir;
    std::wstring m_key;
    FILE*        m_log = nullptr;
};

void sleepFromEnv(const wchar_t* name)
{
    wchar_t buf[32] = {};
    if (GetEnvironmentVariableW(name, buf, 32)) {
        DWORD ms = (DWORD)_wtoi(buf);
        std::wcout << name << L" " << ms << L" ms" << std::endl;
        Sleep(ms);
    }
}

} // anonymous namespace

int wmain(int argc, wchar_t* argv[])
{
    if (argc < 3) {
        std::wcout
            << L"AcDbMText::text() leak reproduction.\n"
            << L"Place exe next to RealDWG binaries (acdb25.dll directory).\n"
            << L"\n"
            << L"Usage: helloworld.exe <registry-key> <iterations> [<dwg-path>]\n"
            << L"\n"
            << L"  <registry-key>  RealDWG machine registry root key for your\n"
            << L"                  application (the key passed to acdbValidateSetup).\n"
            << L"  <iterations>    Number of repro loop iterations.\n"
            << L"  <dwg-path>      Required for MODE=readfile. Path to a .dwg containing one or more MText entities.\n"
            << L"\n"
            << L"Environment variables:\n"
            << L"  MODE              shared | newentity | newdb | readfile | writeread   (default: newentity)\n"
            << L"                      shared    -- one in-memory MText, N text() calls            (no leak)\n"
            << L"                      newentity -- new in-memory MText per iter, same database    (no leak)\n"
            << L"                      newdb     -- new database + new in-memory MText per iter    (no leak)\n"
            << L"                      readfile  -- readDwgFile + find first MText + text() + close, per iter   (LEAKS)\n"
            << L"                      writeread -- generate a temp .dwg with one MText, then run readfile loop (LEAKS)\n"
            << L"  CONTENT_REPEATS   number of payload-sentence repeats (default 2000)\n"
            << L"  CONTENT_PLAIN     '1' = use plain text (no \\f format codes); default = formatted\n"
            << L"  USE_RTF           '1' = call AcDbMText::contentsRTF() instead of text() (negative control)\n"
            << L"  WRITE_PATH        for MODE=writeread, where to save the generated .dwg (default: ./generated.dwg)\n"
            << L"  FINDFILE_LOG      file path to log every findFile() call to (default: disabled)\n"
            << L"  PAUSE_BEFORE_MS   sleep this many ms before the loop (lets you snapshot baseline)\n"
            << L"  PAUSE_AFTER_MS    sleep this many ms after the loop (lets you snapshot peak)\n";
        return 1;
    }

    wchar_t const* appPath  = argv[0];
    wchar_t const* regKey   = argv[1];
    int            iters    = std::stoi(argv[2]);
    wchar_t const* dwgPath  = (argc >= 4) ? argv[3] : nullptr;

    try {
        MinimalHost host(std::filesystem::path(appPath).parent_path().wstring(), regKey);
        if (acdbSetHostApplicationServices(&host) != Acad::eOk) throw std::runtime_error("setHost");
        if (acdbValidateSetup(AcLocale(L"en", L"US")) != Acad::eOk) throw std::runtime_error("validate");

        wchar_t logPath[1024] = {};
        if (GetEnvironmentVariableW(L"FINDFILE_LOG", logPath, 1024)) {
            FILE* f = nullptr;
            _wfopen_s(&f, logPath, L"w");
            if (f) host.setFindFileLog(f);
        }

        // An MText needs a working database back-ref.
        AcDbDatabase db(Adesk::kFalse);
        host.setWorkingDatabase(&db);

        // Build the MText payload.
        wchar_t cbuf[32] = {};
        int repeats = 2000;
        if (GetEnvironmentVariableW(L"CONTENT_REPEATS", cbuf, 32)) repeats = _wtoi(cbuf);
        bool plain = false;
        wchar_t pbuf[8] = {};
        if (GetEnvironmentVariableW(L"CONTENT_PLAIN", pbuf, 8)) plain = (pbuf[0] == L'1');

        std::wstring contents;
        contents.reserve((size_t)repeats * 68);
        if (plain) {
            for (int i = 0; i < repeats; ++i)
                contents += L"The quick brown fox jumps over the lazy dog. ";
        } else {
            for (int i = 0; i < repeats; ++i)
                contents += L"{\\fArial|b0|i0|c0|p34;The quick brown fox jumps over the lazy dog.} ";
        }

        wchar_t modeBuf[32] = L"newentity";
        GetEnvironmentVariableW(L"MODE", modeBuf, 32);
        std::wstring mode(modeBuf);

        // USE_RTF=1 swaps the leaking call AcDbMText::text() for AcDbMText::contentsRTF().
        // Same iteration loop and same entity, but the alternative API does not trigger
        // the leak -- useful as a negative control.
        wchar_t rtfBuf[8] = {};
        bool useRtf = GetEnvironmentVariableW(L"USE_RTF", rtfBuf, 8) && rtfBuf[0] == L'1';

        // writeread: produce a temp DWG with one MText, then continue as readfile.
        std::wstring generatedDwg;
        if (mode == L"writeread") {
            wchar_t outPath[1024] = {};
            if (!GetEnvironmentVariableW(L"WRITE_PATH", outPath, 1024)) {
                // Default: next to the exe.
                auto def = std::filesystem::path(appPath).parent_path() / L"generated.dwg";
                wcsncpy_s(outPath, def.c_str(), _TRUNCATE);
            }

            AcDbDatabase genDb(Adesk::kTrue, Adesk::kFalse);
            AcDbBlockTable* bt = nullptr;
            genDb.getBlockTable(bt, AcDb::kForRead);
            AcDbBlockTableRecord* msRec = nullptr;
            bt->getAt(L"*Model_Space", msRec, AcDb::kForWrite);
            bt->close();

            AcDbMText* mt = new AcDbMText();
            mt->setContents(contents.c_str());
            AcDbObjectId mid;
            msRec->appendAcDbEntity(mid, mt);
            mt->close();
            msRec->close();

            Acad::ErrorStatus sv = genDb.saveAs(outPath);
            std::wcout << L"  saveAs => " << sv << L"  path=" << outPath << std::endl;
            generatedDwg = outPath;
            dwgPath = generatedDwg.c_str();
            mode = L"readfile";
        }

        std::wcout
            << L"AcDbMText::text() leak reproduction initialized.\n"
            << L"  Contents wchar count: " << contents.length() << L"\n"
            << L"  Iterations:           " << iters << L"\n"
            << L"  Mode:                 " << mode << L"\n"
            << L"  Call:                 " << (useRtf ? L"contentsRTF()" : L"text()") << L"\n"
            << std::flush;

        sleepFromEnv(L"PAUSE_BEFORE_MS");

        AcDbMText* pSharedMText = nullptr;
        if (mode == L"shared") {
            pSharedMText = new AcDbMText();
            pSharedMText->setContents(contents.c_str());
        }

        for (int i = 0; i < iters; ++i) {
            AcString out;
            Acad::ErrorStatus s = Acad::eOk;

            if (mode == L"shared") {
                s = useRtf ? pSharedMText->contentsRTF(out) : pSharedMText->text(out);
            } else if (mode == L"newdb") {
                AcDbDatabase iterDb(Adesk::kFalse);
                AcDbDatabase* prev = host.workingDatabase();
                host.setWorkingDatabase(&iterDb);
                AcDbMText* pM = new AcDbMText();
                pM->setContents(contents.c_str());
                s = useRtf ? pM->contentsRTF(out) : pM->text(out);
                delete pM;
                host.setWorkingDatabase(prev);
            } else if (mode == L"readfile") {
                if (!dwgPath) {
                    std::wcerr << L"MODE=readfile requires <dwg-path> argument." << std::endl;
                    s = Acad::eFilerError;
                    break;
                }
                AcDbDatabase iterDb(Adesk::kFalse);
                AcDbDatabase* prev = host.workingDatabase();
                host.setWorkingDatabase(&iterDb);
                s = iterDb.readDwgFile(dwgPath);
                if (s == Acad::eOk) {
                    AcDbBlockTable* bt = nullptr;
                    s = iterDb.getBlockTable(bt, AcDb::kForRead);
                    if (s == Acad::eOk) {
                        AcDbBlockTableIterator* it = nullptr;
                        bt->newIterator(it);
                        bool got = false;
                        while (it && !it->done() && !got) {
                            AcDbBlockTableRecord* rec = nullptr;
                            if (it->getRecord(rec, AcDb::kForRead) == Acad::eOk) {
                                AcDbBlockTableRecordIterator* rit = nullptr;
                                rec->newIterator(rit);
                                while (rit && !rit->done() && !got) {
                                    AcDbEntity* ent = nullptr;
                                    if (rit->getEntity(ent, AcDb::kForRead) == Acad::eOk) {
                                        AcDbMText* mt = AcDbMText::cast(ent);
                                        if (mt) {
                                            if (useRtf) mt->contentsRTF(out);   // negative control: same loop, no leak
                                            else        mt->text(out);          // <-- the leaking call
                                            got = true;
                                        }
                                        ent->close();
                                    }
                                    rit->step();
                                }
                                delete rit;
                                rec->close();
                            }
                            it->step();
                        }
                        delete it;
                        bt->close();
                    }
                }
                host.setWorkingDatabase(prev);
            } else {
                // newentity (default): new in-memory MText per iter, same db.
                AcDbMText* pM = new AcDbMText();
                pM->setContents(contents.c_str());
                s = useRtf ? pM->contentsRTF(out) : pM->text(out);
                delete pM;
            }

            if (s != Acad::eOk) {
                std::wcerr << L"text() failed with " << s << L" at iter " << i << std::endl;
                break;
            }
            if (i == 0 || ((i + 1) % 50) == 0)
                std::wcout << L"  iter " << (i + 1) << L"  text len=" << out.length() << std::endl;
        }

        sleepFromEnv(L"PAUSE_AFTER_MS");

        delete pSharedMText;
        host.setWorkingDatabase(nullptr);

        acdbCleanUp();
    } catch (std::exception const& e) {
        std::wcerr << L"Exception: " << e.what() << std::endl;
        return -1;
    }

    return 0;
}
