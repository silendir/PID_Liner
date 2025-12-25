# PID_Liner Podfile
# 用于管理第三方依赖库

platform :ios, '13.0'
use_frameworks!

target 'PID_Liner' do
  # 图表库 - AAChartKit
  # 用于绘制PID分析图表（折线图、面积图等）
  pod 'AAChartKit', :git => 'https://github.com/AAChartModel/AAChartKit.git'

end

post_install do |installer|
  # 确保CocoaPods生成的项目使用正确的架构
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end

  # 禁用用户脚本沙盒以修复rsync权限问题
  installer.pods_project.build_configurations.each do |config|
    config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  end

  # 主项目也禁用
  installer.generated_projects.each do |project|
    project.build_configurations.each do |config|
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end
end
