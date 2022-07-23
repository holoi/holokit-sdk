using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.XR.ARFoundation;

namespace HoloKit
{
    public class HoloKitUtility : MonoBehaviour
    {
        [SerializeField] private string[] _arSceneNames;

        private void Awake()
        {
            DontDestroyOnLoad(gameObject);
            HoloKitNFCSessionControllerAPI.RegisterNFCSessionControllerDelegates();
            HoloKitARSessionControllerAPI.RegisterARSessionControllerDelegates();
            HoloKitARSessionControllerAPI.InterceptUnityARSessionDelegate();
            SceneManager.sceneUnloaded += OnSceneUnloaded;
        }

        private void OnDestroy()
        {
            SceneManager.sceneUnloaded -= OnSceneUnloaded;
        }

        private void OnSceneUnloaded(Scene scene)
        {
            foreach (var arSceneName in _arSceneNames)
            {
                if (scene.name.Equals(arSceneName))
                {
                    LoaderUtility.Deinitialize();
                    LoaderUtility.Initialize();
                    HoloKitARSessionControllerAPI.InterceptUnityARSessionDelegate();
                    return;
                }
            }
        }
    }
}
