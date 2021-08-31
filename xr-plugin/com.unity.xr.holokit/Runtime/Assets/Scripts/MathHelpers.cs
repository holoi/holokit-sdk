using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace UnityEngine.XR.HoloKit
{
    public class MathHelpers
    {
        public static Vector3 GetCenterEyePosition(Transform camera)
        {
            return camera.position + camera.TransformVector(HoloKitSettings.CameraToCenterEyeOffset);
        }

        public static Quaternion GetCameraVerticalRotation(Transform camera)
        {
            Vector3 cameraEuler = camera.rotation.eulerAngles;
            return Quaternion.Euler(new Vector3(0f, cameraEuler.y, 0f));
        }
    }
}
