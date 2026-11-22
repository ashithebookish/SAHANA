# SAHANA API

SAHANA is a local FastAPI prototype for routine tracking, check-ins, scheduled care, help requests, chat, and consent-controlled camera testing.

## Start the browser camera test

1. Extract **SAHANA-API.zip** into a writable folder. Use Python 3.10 or newer. First-time setup downloads Python dependencies.
2. On a Mac, double-click **Start SAHANA API.command**. From Terminal on macOS or Linux, run the following from the extracted folder.

   ```sh
   bash "./Start SAHANA API.command"
   ```

3. Open the camera test URL printed in Terminal and copy the generated test token into the page’s password field. Keep Terminal open while testing. The default URL is [http://127.0.0.1:8012/camera-test](http://127.0.0.1:8012/camera-test). If that port is occupied, add `--port 8013` to the launch command.
4. Use a consenting participant in a clear view. Grant the browser permission to use the webcam when prompted. Start the webcam test and confirm the preview and API relay status appear. Use the page’s stop control when finished, then press Control-C in Terminal.

The browser test works on loopback and uses a temporary SQLite database and a newly generated token. The relayed preview stays on this device, and a normal shutdown removes the test database.

The same launcher is available directly in Python.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m scripts.judge_api
```

For Windows PowerShell, the direct launcher commands are below. The ZIP was verified on macOS.

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m scripts.judge_api
```

## Use the REST API

The reference is at `/docs` and the machine-readable contract is at `/openapi.json`. Use the same port and token shown in Terminal.

```sh
base=http://127.0.0.1:8012
read -r -s token
# Paste the terminal's local test token and press Enter.
curl --noproxy '*' -fsS "$base/status"
curl --noproxy '*' -fsS -H "Authorization: Bearer $token" "$base/people"
unset token
```

## Try the workflows without a camera

Use the virtual environment created above. The demo and replay use separate synthetic databases.

```sh
.venv/bin/python -m scripts.demo
.venv/bin/python -m scripts.replay --output replay.json --report replay.txt
.venv/bin/python -m pytest -q
```

You can also start the synthetic API service with `bash "./Start SAHANA API.command" --demo` on macOS or Linux.

## Optional seat recognition on a Mac

The browser page checks the webcam relay. The SwiftUI client runs Vision on the Mac and can identify rising and lowering from a seat. It sends accepted movement labels to the API.

1. Use a Mac running macOS 14 or newer with Xcode or the Swift 6 command line tools.
2. Stop the browser camera session before starting the desktop client. Run `bash "./Start SAHANA.command"` from the extracted folder.
3. In **Caregiver hub**, add a test profile. Use **Patient screen** to enable camera and movement monitoring with the participant’s consent.
4. Return to **Caregiver hub**, select the profile, select **Start this Mac’s camera**, then choose **Start with seat-motion detection**. Use a fixed camera and keep the participant’s shoulders, hips and knees in view. Guide the participant to move at a comfortable pace. Review recognized observations in the caregiver movement history or at `GET /events?person=ID&kind=motion`.

The local API is designed for prototypes with test data. Upload or link the package as the prototype download so judges can run it on their own device. The [source license](LICENSE) and [third-party disclosures](NOTICE) are included.
